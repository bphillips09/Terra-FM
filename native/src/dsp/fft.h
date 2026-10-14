#pragma once

#include <complex>
#include <cstddef>
#include <vector>

namespace terra {

// Iterative radix-2 complex FFT for power-of-two sizes. Matches FFTW's
// unnormalized convention: forward computes X[k] = sum x[n] e^{-2πikn/N}.
class Fft {
 public:
  explicit Fft(size_t n);

  size_t size() const { return n_; }

  // Out-of-place (in != out) or in-place (in == out) transform.
  void forward(const std::complex<float>* in, std::complex<float>* out) const;
  void inverse(const std::complex<float>* in, std::complex<float>* out) const;

  static bool is_power_of_two(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

 private:
  void transform(const std::complex<float>* in, std::complex<float>* out,
                 bool inverse) const;

  size_t n_;
  std::vector<size_t> bitrev_;
  std::vector<std::complex<float>> twiddles_;  // e^{-2πik/N}, k < N/2
};

}  // namespace terra
