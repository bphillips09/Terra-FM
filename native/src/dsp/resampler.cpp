#include "dsp/resampler.h"

#include <algorithm>
#include <cmath>

#include "dsp/fir.h"

namespace terra {

void Resampler::configure(double in_rate, double out_rate, size_t channels, size_t taps,
                          size_t phases) {
  channels_ = std::max<size_t>(1, channels);
  taps_ = std::max<size_t>(4, taps & ~size_t{1});
  phases_ = std::max<size_t>(16, phases);
  step_ = in_rate / out_rate;
  trim_ = 1.0;

  // Prototype low-pass at phases * in_rate. Cut off a little below the lower
  // Nyquist so downsampling does not alias.
  const double nyquist_fraction = 0.5 * std::min(1.0, out_rate / in_rate) * 0.92;
  const size_t length = taps_ * phases_ + 1;
  table_ = design_lowpass(length, nyquist_fraction, static_cast<double>(phases_),
                          kaiser_beta_for_attenuation(80.0));
  for (auto& c : table_) c *= static_cast<float>(phases_);
  coeffs_.resize(taps_);
  reset();
}

void Resampler::reset() {
  history_.assign(taps_ * channels_, 0.0f);
  position_ = static_cast<double>(taps_ / 2 - 1);
}

void Resampler::process(const float* in, size_t frames, std::vector<float>& out) {
  history_.insert(history_.end(), in, in + frames * channels_);
  const size_t available = history_.size() / channels_;
  const size_t half = taps_ / 2;
  const double step = step_ * trim_;

  while (true) {
    const auto base = static_cast<size_t>(position_);
    if (base + half >= available) break;
    const double frac = position_ - static_cast<double>(base);
    const double pf = frac * static_cast<double>(phases_);
    const auto p = static_cast<size_t>(pf);
    const auto mu = static_cast<float>(pf - static_cast<double>(p));

    // Input frame first + k sits at kernel offset (taps - 1 - k - half) + frac.
    for (size_t k = 0; k < taps_; ++k) {
      const size_t j = (taps_ - 1 - k) * phases_ + p;
      coeffs_[k] = table_[j] + mu * (table_[j + 1] - table_[j]);
    }
    const size_t first = base + half + 1 - taps_;
    for (size_t c = 0; c < channels_; ++c) {
      float acc = 0.0f;
      const float* x = &history_[first * channels_ + c];
      for (size_t k = 0; k < taps_; ++k) acc += coeffs_[k] * x[k * channels_];
      out.push_back(acc);
    }
    position_ += step;
  }

  // Drop input that no future output needs.
  const auto base = static_cast<size_t>(position_);
  const size_t keep_from = base + half + 1 >= taps_ ? base + half + 1 - taps_ : 0;
  if (keep_from > 0) {
    const size_t drop = std::min(keep_from, available);
    history_.erase(history_.begin(), history_.begin() + static_cast<std::ptrdiff_t>(drop * channels_));
    position_ -= static_cast<double>(drop);
  }
}

}  // namespace terra
