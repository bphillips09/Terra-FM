#include "audio/mixer.h"

#include <algorithm>
#include <cstdlib>

namespace terra {

AudioMixer::AudioMixer()
    // nrsc5 releases HD audio in ~93 ms bursts; the queue must stay deeper
    // than the lookahead or burst gaps look like dropouts.
    : prefill_frames_(kSampleRate * 3 / 10),     // 300 ms
      crossfade_frames_(kSampleRate / 10),       // 100 ms lookahead + fade
      recover_frames_(kSampleRate),              // 1 s of clean HD before blending back
      max_queue_frames_(kSampleRate * 4) {}

void AudioMixer::reset() {
  hd_frames_.clear();
  hd_valid_.clear();
  hd_read_ = 0;
  hd_started_ = false;
  hd_ever_started_ = false;
  good_run_ = 0;
  hd_gain_ = 0.0f;
  hd_target_ = false;
  analog_delay_.clear();
  analog_read_ = 0;
}

void AudioMixer::set_program(int program) {
  if (program == program_) return;
  program_ = program;
  hd_frames_.clear();
  hd_valid_.clear();
  hd_read_ = 0;
  hd_started_ = false;
  hd_ever_started_ = false;
  good_run_ = 0;
  // Different program content: cut rather than crossfade.
  hd_gain_ = 0.0f;
  hd_target_ = false;
}

void AudioMixer::set_hd_level(float level) { hd_level_ = std::clamp(level, 0.25f, 4.0f); }

void AudioMixer::set_alignment_ms(int ms) {
  const size_t frames = static_cast<size_t>(std::abs(ms)) * kSampleRate / 1000;
  hd_delay_frames_ = ms > 0 ? frames : 0;
  analog_delay_frames_ = ms < 0 ? frames : 0;
}

void AudioMixer::push_hd(const int16_t* frames, size_t frame_count, bool valid) {
  constexpr float kScale = 1.0f / 32768.0f;
  const size_t start = hd_frames_.size();
  hd_frames_.resize(start + frame_count * 2);
  for (size_t i = 0; i < frame_count * 2; ++i) hd_frames_[start + i] = frames[i] * kScale;
  hd_valid_.insert(hd_valid_.end(), frame_count, valid ? 1 : 0);

  // Bound latency if the consumer stalls.
  const size_t queued = hd_queue_frames();
  if (queued > max_queue_frames_ + hd_delay_frames_) {
    hd_read_ += queued - start_depth();
    compact();
  }
}

bool AudioMixer::hd_valid_at(size_t offset) const {
  const size_t idx = hd_read_ + offset;
  if (idx >= hd_valid_.size()) return false;
  return hd_valid_[idx] != 0;
}

bool AudioMixer::analog_allowed() const {
  if (mode_ == TERRA_AUDIO_MODE_ANALOG) return true;
  if (mode_ == TERRA_AUDIO_MODE_DIGITAL) return false;
  return program_ == 0;  // analog carries HD1's program only
}

terra_audio_source AudioMixer::active_source() const {
  if (mode_ != TERRA_AUDIO_MODE_ANALOG && hd_gain_ > 0.5f) return TERRA_AUDIO_SOURCE_HD;
  if (analog_allowed() && !last_analog_squelched_) return TERRA_AUDIO_SOURCE_ANALOG;
  return TERRA_AUDIO_SOURCE_NONE;
}

void AudioMixer::compact() {
  if (hd_read_ == 0) return;
  hd_frames_.erase(hd_frames_.begin(), hd_frames_.begin() + static_cast<std::ptrdiff_t>(hd_read_ * 2));
  hd_valid_.erase(hd_valid_.begin(), hd_valid_.begin() + static_cast<std::ptrdiff_t>(hd_read_));
  hd_read_ = 0;
}

void AudioMixer::mix(const float* analog, size_t frame_count, bool analog_squelched,
                     std::vector<float>& out) {
  last_analog_squelched_ = analog_squelched;

  // Analog delay line.
  analog_delay_.insert(analog_delay_.end(), analog, analog + frame_count * 2);

  const bool digital_wanted = mode_ != TERRA_AUDIO_MODE_ANALOG;
  const bool analog_ok = analog_allowed();
  const float fade_step = 1.0f / static_cast<float>(crossfade_frames_);

  if (!hd_started_ && digital_wanted && hd_queue_frames() >= start_depth()) {
    // Start once the queue holds real audio.
    bool any_valid = false;
    for (size_t k = 0; k < start_depth(); ++k) {
      if (hd_valid_at(k)) {
        any_valid = true;
        break;
      }
    }
    if (any_valid) {
      hd_started_ = true;
      if (!hd_ever_started_) good_run_ = recover_frames_;
      hd_ever_started_ = true;
    } else {
      hd_read_ += hd_queue_frames() - start_depth() / 2;  // drop stale silence
    }
  }

  const size_t start = out.size();
  out.resize(start + frame_count * 2);
  for (size_t k = 0; k < frame_count; ++k) {
    float al = 0.0f, ar = 0.0f;
    const size_t delayed_frames = (analog_delay_.size() / 2) - analog_read_;
    if (delayed_frames > analog_delay_frames_) {
      al = analog_delay_[analog_read_ * 2];
      ar = analog_delay_[analog_read_ * 2 + 1];
      ++analog_read_;
    }

    float hl = 0.0f, hr = 0.0f;
    bool frame_valid = false;
    if (hd_started_) {
      if (hd_read_ < hd_valid_.size()) {
        hl = hd_frames_[hd_read_ * 2];
        hr = hd_frames_[hd_read_ * 2 + 1];
        frame_valid = hd_valid_[hd_read_] != 0;
        ++hd_read_;
      } else {
        hd_started_ = false;  // underflow: re-prefill
      }
    }
    good_run_ = frame_valid ? good_run_ + 1 : 0;

    if (!digital_wanted || !hd_started_) {
      hd_target_ = false;
    } else if (!analog_ok) {
      hd_target_ = true;  // nothing to fall back to
    } else {
      const bool ahead_ok = frame_valid && hd_valid_at(crossfade_frames_);
      if (hd_target_) {
        hd_target_ = ahead_ok;
      } else {
        hd_target_ = ahead_ok && good_run_ >= recover_frames_;
      }
    }

    if (hd_target_) hd_gain_ = std::min(1.0f, hd_gain_ + fade_step);
    else hd_gain_ = std::max(0.0f, hd_gain_ - fade_step);

    const float analog_gain = analog_ok ? 1.0f - hd_gain_ : 0.0f;
    const float hd = hd_gain_ * hd_level_;
    out[start + 2 * k] = hd * hl + analog_gain * al;
    out[start + 2 * k + 1] = hd * hr + analog_gain * ar;
  }

  if (analog_read_ > 0 && analog_read_ * 2 >= analog_delay_.size() / 2) {
    analog_delay_.erase(analog_delay_.begin(),
                        analog_delay_.begin() + static_cast<std::ptrdiff_t>(analog_read_ * 2));
    analog_read_ = 0;
  }
  if (hd_read_ > kSampleRate) compact();
}

}  // namespace terra
