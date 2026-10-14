#include "dsp/fft.h"

#include <cmath>
#include <stdexcept>
#include <utility>

#include "dsp/math.h"

namespace terra {

Fft::Fft(size_t n) : n_(n) {
  if (!is_power_of_two(n)) {
    throw std::invalid_argument("FFT size must be a power of two");
  }
  size_t bits = 0;
  while ((size_t{1} << bits) < n) ++bits;

  bitrev_.resize(n);
  for (size_t i = 0; i < n; ++i) {
    size_t r = 0;
    for (size_t b = 0; b < bits; ++b) {
      if (i & (size_t{1} << b)) r |= size_t{1} << (bits - 1 - b);
    }
    bitrev_[i] = r;
  }

  twiddles_.resize(n / 2);
  for (size_t k = 0; k < n / 2; ++k) {
    const double angle = -2.0 * kPi * static_cast<double>(k) / static_cast<double>(n);
    twiddles_[k] = {static_cast<float>(std::cos(angle)), static_cast<float>(std::sin(angle))};
  }
}

void Fft::forward(const std::complex<float>* in, std::complex<float>* out) const {
  transform(in, out, false);
}

void Fft::inverse(const std::complex<float>* in, std::complex<float>* out) const {
  transform(in, out, true);
}

void Fft::transform(const std::complex<float>* in, std::complex<float>* out,
                    bool inverse) const {
  if (in == out) {
    for (size_t i = 0; i < n_; ++i) {
      const size_t j = bitrev_[i];
      if (j > i) std::swap(out[i], out[j]);
    }
  } else {
    for (size_t i = 0; i < n_; ++i) out[bitrev_[i]] = in[i];
  }

  for (size_t len = 2; len <= n_; len <<= 1) {
    const size_t half = len >> 1;
    const size_t stride = n_ / len;
    for (size_t start = 0; start < n_; start += len) {
      for (size_t k = 0; k < half; ++k) {
        std::complex<float> w = twiddles_[k * stride];
        if (inverse) w = std::conj(w);
        const std::complex<float> a = out[start + k];
        const std::complex<float> b = out[start + k + half];
        // Manual complex multiply avoids the NaN/Inf handling in operator*.
        const std::complex<float> t(b.real() * w.real() - b.imag() * w.imag(),
                                    b.real() * w.imag() + b.imag() * w.real());
        out[start + k] = a + t;
        out[start + k + half] = a - t;
      }
    }
  }
}

}  // namespace terra
