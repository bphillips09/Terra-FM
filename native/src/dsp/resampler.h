#pragma once

#include <cstddef>
#include <vector>

namespace terra {

// Polyphase windowed-sinc resampler for interleaved float frames. Supports any
// ratio, plus a fine ratio trim for clock-drift correction.
class Resampler {
 public:
  Resampler() = default;
  Resampler(double in_rate, double out_rate, size_t channels, size_t taps = 32,
            size_t phases = 256) {
    configure(in_rate, out_rate, channels, taps, phases);
  }

  void configure(double in_rate, double out_rate, size_t channels, size_t taps = 32,
                 size_t phases = 256);
  void reset();

  // Multiplies the input step; >1 consumes input faster (output fewer frames).
  void set_trim(double trim) { trim_ = trim; }
  double trim() const { return trim_; }

  // Appends resampled interleaved frames to `out`.
  void process(const float* in, size_t frames, std::vector<float>& out);

  size_t channels() const { return channels_; }
  // Input frames held back inside the filter.
  size_t latency_frames() const { return taps_ / 2; }

 private:
  size_t channels_ = 1;
  size_t taps_ = 32;
  size_t phases_ = 256;
  double step_ = 1.0;  // input frames per output frame
  double trim_ = 1.0;
  std::vector<float> table_;   // taps * phases + 1 coefficients
  std::vector<float> history_; // interleaved input frames
  double position_ = 0.0;      // fractional input index of next output (relative to history start)
  std::vector<float> coeffs_;
};

}  // namespace terra
