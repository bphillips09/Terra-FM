#include "dsp/fir.h"

#include <algorithm>
#include <cmath>

#include "dsp/math.h"

namespace terra {

namespace {

double bessel_i0(double x) {
  double sum = 1.0;
  double term = 1.0;
  const double half = x / 2.0;
  for (int k = 1; k < 64; ++k) {
    term *= (half / k) * (half / k);
    sum += term;
    if (term < sum * 1e-12) break;
  }
  return sum;
}

}  // namespace

double kaiser_beta_for_attenuation(double a) {
  if (a > 50.0) return 0.1102 * (a - 8.7);
  if (a >= 21.0) return 0.5842 * std::pow(a - 21.0, 0.4) + 0.07886 * (a - 21.0);
  return 0.0;
}

std::vector<float> design_lowpass(size_t taps, double cutoff_hz, double sample_rate_hz,
                                  double kaiser_beta) {
  std::vector<double> h(taps);
  const double fc = cutoff_hz / sample_rate_hz;  // cycles per sample
  const double m = static_cast<double>(taps - 1);
  const double i0_beta = bessel_i0(kaiser_beta);
  double sum = 0.0;
  for (size_t n = 0; n < taps; ++n) {
    const double x = static_cast<double>(n) - m / 2.0;
    const double sinc = std::abs(x) < 1e-9 ? 2.0 * fc : std::sin(2.0 * kPi * fc * x) / (kPi * x);
    const double r = m > 0 ? (2.0 * static_cast<double>(n) / m - 1.0) : 0.0;
    const double window = bessel_i0(kaiser_beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0_beta;
    h[n] = sinc * window;
    sum += h[n];
  }
  std::vector<float> out(taps);
  for (size_t n = 0; n < taps; ++n) out[n] = static_cast<float>(h[n] / sum);
  return out;
}

float dot_product(const float* a, const float* b, size_t n) {
  // Four independent accumulators let the compiler vectorize without
  // needing -ffast-math reassociation.
  float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
  size_t i = 0;
  for (; i + 4 <= n; i += 4) {
    s0 += a[i] * b[i];
    s1 += a[i + 1] * b[i + 1];
    s2 += a[i + 2] * b[i + 2];
    s3 += a[i + 3] * b[i + 3];
  }
  for (; i < n; ++i) s0 += a[i] * b[i];
  return (s0 + s1) + (s2 + s3);
}

template <size_t Channels>
void FirDecimator<Channels>::configure(std::vector<float> taps, size_t decimation) {
  taps_.assign(taps.rbegin(), taps.rend());
  decimation_ = std::max<size_t>(1, decimation);
  reset();
}

template <size_t Channels>
void FirDecimator<Channels>::reset() {
  const size_t hist = taps_.empty() ? 0 : taps_.size() - 1;
  for (auto& h : history_) h.assign(hist, 0.0f);
  next_ = hist;
}

template <size_t Channels>
size_t FirDecimator<Channels>::process(const std::array<const float*, Channels>& in, size_t n,
                                       std::array<std::vector<float>*, Channels> out) {
  if (taps_.empty() || n == 0) return 0;
  const size_t ntaps = taps_.size();
  const size_t hist = ntaps - 1;

  for (size_t c = 0; c < Channels; ++c) {
    history_[c].insert(history_[c].end(), in[c], in[c] + n);
  }
  const size_t total = history_[0].size();

  size_t produced = 0;
  while (next_ < total) {
    const size_t start = next_ - hist;
    for (size_t c = 0; c < Channels; ++c) {
      out[c]->push_back(dot_product(&history_[c][start], taps_.data(), ntaps));
    }
    next_ += decimation_;
    ++produced;
  }

  // Keep the last `hist` samples and rebase indices.
  const size_t drop = total - hist;
  for (size_t c = 0; c < Channels; ++c) {
    history_[c].erase(history_[c].begin(), history_[c].begin() + static_cast<std::ptrdiff_t>(drop));
  }
  next_ -= drop;
  return produced;
}

template class FirDecimator<1>;
template class FirDecimator<2>;

}  // namespace terra
