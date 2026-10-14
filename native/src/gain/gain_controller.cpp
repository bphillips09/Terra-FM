#include "gain/gain_controller.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

#include "terra_core.h"

namespace terra {

namespace {
constexpr int64_t kSettleUs = 300000;      // tuner + nrsc5 settle after a step
constexpr int64_t kMeasureHdUs = 3200000;  // ~2 MER reports
constexpr int64_t kMeasureFmUs = 800000;
constexpr float kClipRatioLimit = 0.002f;
constexpr float kRmsHighDb = -8.0f;
constexpr float kRmsLowDb = -22.0f;
constexpr float kRmsRefineCeilingDb = -10.0f;
constexpr double kImprovementDb = 0.3;
constexpr int kMaxRefineSteps = 8;
constexpr int kMaxSearchSteps = 30;
}  // namespace

void GainController::set_available_gains(std::vector<int> gains) {
  std::sort(gains.begin(), gains.end());
  gains.erase(std::unique(gains.begin(), gains.end()), gains.end());
  gains_ = std::move(gains);
  index_ = std::min<int>(index_, static_cast<int>(gains_.size()) - 1);
  if (index_ < 0) index_ = 0;
}

void GainController::set_mode(int mode, int manual_tenth_db) {
  mode_ = mode;
  manual_ = manual_tenth_db;
}

int GainController::nearest_index(int tenth_db) const {
  int best = 0;
  int best_diff = 1 << 30;
  for (int i = 0; i < static_cast<int>(gains_.size()); ++i) {
    const int diff = std::abs(gains_[static_cast<size_t>(i)] - tenth_db);
    if (diff < best_diff) {
      best_diff = diff;
      best = i;
    }
  }
  return best;
}

int GainController::current_gain() const {
  if (mode_ == TERRA_GAIN_HARDWARE_AGC) return kHardwareAgc;
  if (gains_.empty()) return mode_ == TERRA_GAIN_MANUAL ? manual_ : 0;
  return gains_[static_cast<size_t>(index_)];
}

int GainController::apply(int index, int64_t now_us) {
  index_ = std::clamp(index, 0, static_cast<int>(gains_.size()) - 1);
  settle_until_us_ = now_us + kSettleUs;
  return gains_[static_cast<size_t>(index_)];
}

void GainController::start_measure(int64_t now_us) {
  quality_sum_ = 0.0;
  quality_count_ = 0;
  measure_until_us_ = 0;
  (void)now_us;
}

int GainController::begin(int hint, int64_t now_us) {
  converged_ = false;
  converged_event_ = false;
  clip_reports_ = 0;
  search_steps_ = 0;
  if (mode_ == TERRA_GAIN_HARDWARE_AGC) return kHardwareAgc;
  if (gains_.empty()) return mode_ == TERRA_GAIN_MANUAL ? manual_ : kNoChange;
  if (mode_ == TERRA_GAIN_MANUAL) return apply(nearest_index(manual_), now_us);

  if (hint >= 0) {
    // Trust the cached gain; refine only if it misbehaves.
    phase_ = Phase::kHold;
    converged_ = true;
    hold_rms_db_ = 0.0f;
    return apply(nearest_index(hint), now_us);
  }
  phase_ = Phase::kSearch;
  // Start around 60% of the range: strong local stations rarely need more.
  const int start = static_cast<int>(std::lround((gains_.size() - 1) * 0.6));
  return apply(start, now_us);
}

int GainController::update(const SignalReport& s, bool hd_synced, const HdQuality& hd,
                           float fm_cnr_db, int64_t now_us) {
  if (mode_ != TERRA_GAIN_AUTO || gains_.empty()) return kNoChange;
  if (now_us < settle_until_us_) return kNoChange;
  const int top = static_cast<int>(gains_.size()) - 1;
  const bool clipping = s.clip_ratio > kClipRatioLimit;

  switch (phase_) {
    case Phase::kSearch: {
      if (++search_steps_ > kMaxSearchSteps) {
        phase_ = Phase::kRefine;
        break;
      }
      if (clipping && index_ > 0) return apply(index_ - 3, now_us);
      if (s.rms_dbfs > kRmsHighDb && index_ > 0) return apply(index_ - 1, now_us);
      if (s.rms_dbfs < kRmsLowDb && index_ < top) {
        return apply(index_ + (s.rms_dbfs < kRmsLowDb - 6.0f ? 2 : 1), now_us);
      }
      phase_ = Phase::kRefine;
      best_quality_ = -1e9;
      best_index_ = index_;
      direction_ = +1;
      steps_ = 0;
      tried_other_direction_ = false;
      start_measure(now_us);
      return kNoChange;
    }

    case Phase::kRefine: {
      if (clipping && index_ > 0) {
        // Never trade clipping for quality.
        best_index_ = std::min(best_index_, index_ - 1);
        phase_ = Phase::kHold;
        converged_ = converged_event_ = true;
        hold_rms_db_ = s.rms_dbfs;
        return apply(best_index_, now_us);
      }
      if (measure_until_us_ == 0) {
        measuring_hd_ = hd_synced;
        measure_until_us_ = now_us + (hd_synced ? kMeasureHdUs : kMeasureFmUs);
        last_mer_us_ = hd.updated_us;
      }
      if (measuring_hd_) {
        if (hd.valid && hd.updated_us != last_mer_us_) {
          last_mer_us_ = hd.updated_us;
          quality_sum_ += 0.5 * (hd.mer_lower + hd.mer_upper);
          ++quality_count_;
        }
      } else {
        quality_sum_ += fm_cnr_db;
        ++quality_count_;
      }
      if (now_us < measure_until_us_ || quality_count_ == 0) return kNoChange;

      const double quality = quality_sum_ / quality_count_;
      start_measure(now_us);
      if (quality > best_quality_ + kImprovementDb || steps_ == 0) {
        best_quality_ = quality;
        best_index_ = index_;
      } else {
        // Worse or equal: go back and try the other direction once.
        if (!tried_other_direction_) {
          tried_other_direction_ = true;
          direction_ = -direction_;
          ++steps_;
          return apply(best_index_ + direction_, now_us);
        }
        phase_ = Phase::kHold;
        converged_ = converged_event_ = true;
        hold_rms_db_ = s.rms_dbfs;
        return best_index_ != index_ ? apply(best_index_, now_us) : kNoChange;
      }

      const int next = index_ + direction_;
      const bool headroom = direction_ < 0 || (s.rms_dbfs < kRmsRefineCeilingDb && s.clip_ratio == 0.0f);
      if (steps_ >= kMaxRefineSteps || next < 0 || next > top || !headroom) {
        if (!tried_other_direction_) {
          tried_other_direction_ = true;
          direction_ = -direction_;
          const int other = best_index_ + direction_;
          if (other >= 0 && other <= top) {
            ++steps_;
            return apply(other, now_us);
          }
        }
        phase_ = Phase::kHold;
        converged_ = converged_event_ = true;
        hold_rms_db_ = s.rms_dbfs;
        return best_index_ != index_ ? apply(best_index_, now_us) : kNoChange;
      }
      ++steps_;
      return apply(next, now_us);
    }

    case Phase::kHold: {
      if (hold_rms_db_ == 0.0f) hold_rms_db_ = s.rms_dbfs;
      clip_reports_ = clipping ? clip_reports_ + 1 : 0;
      const bool level_jump = std::abs(s.rms_dbfs - hold_rms_db_) > 12.0f;
      if (clip_reports_ >= 3 || level_jump) {
        phase_ = Phase::kSearch;
        converged_ = false;
        search_steps_ = 0;
        clip_reports_ = 0;
      }
      return kNoChange;
    }
  }
  return kNoChange;
}

}  // namespace terra
