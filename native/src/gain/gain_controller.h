#pragma once

#include <cstdint>
#include <vector>

#include "dsp/signal_meter.h"
#include "hd/hd_decoder.h"

namespace terra {

// Software gain control for RTL-SDR tuners.
//
// AUTO: an amplitude search first gets the IQ level into a safe window (no
// clipping, enough level for the 8-bit ADC), then a hill climb on decode
// quality (HD MER when synced, otherwise analog CNR) picks the best nearby
// gain step and holds it. MANUAL and HARDWARE_AGC pass straight through.
class GainController {
 public:
  static constexpr int kHardwareAgc = -2;
  static constexpr int kNoChange = -1;

  void set_available_gains(std::vector<int> gains_tenth_db);
  const std::vector<int>& available_gains() const { return gains_; }

  void set_mode(int mode, int manual_tenth_db);
  int mode() const { return mode_; }

  // On tune/open. Returns the gain to apply (tenths of dB) or kHardwareAgc.
  int begin(int hint_tenth_db, int64_t now_us);

  // Per signal report. Returns a new gain to apply, or kNoChange.
  int update(const SignalReport& signal, bool hd_synced, const HdQuality& hd, float fm_cnr_db,
             int64_t now_us);

  int current_gain() const;
  bool converged() const { return converged_; }
  // True once after `converged()` flips to true.
  bool take_converged_event() {
    const bool e = converged_event_;
    converged_event_ = false;
    return e;
  }

 private:
  enum class Phase { kSearch, kRefine, kHold };

  int nearest_index(int tenth_db) const;
  int apply(int index, int64_t now_us);
  void start_measure(int64_t now_us);

  std::vector<int> gains_;
  int mode_ = 0;
  int manual_ = 300;
  int index_ = 0;
  Phase phase_ = Phase::kSearch;
  int64_t settle_until_us_ = 0;
  bool converged_ = false;
  bool converged_event_ = false;

  // Refinement state.
  double best_quality_ = -1e9;
  int best_index_ = 0;
  int direction_ = +1;
  int steps_ = 0;
  bool tried_other_direction_ = false;
  double quality_sum_ = 0.0;
  int quality_count_ = 0;
  int64_t last_mer_us_ = 0;
  int64_t measure_until_us_ = 0;
  bool measuring_hd_ = false;

  // Hold state.
  float hold_rms_db_ = 0.0f;
  int clip_reports_ = 0;
  int search_steps_ = 0;
};

}  // namespace terra
