#pragma once

#include <array>
#include <cstddef>
#include <vector>

namespace terra {

// Windowed-sinc low-pass design (Kaiser window), normalized to unity DC gain.
std::vector<float> design_lowpass(size_t taps, double cutoff_hz, double sample_rate_hz,
                                  double kaiser_beta);

// Kaiser beta for a desired stopband attenuation in dB.
double kaiser_beta_for_attenuation(double attenuation_db);

// Decimating FIR applied to `Channels` planar float streams that share the
// same taps (e.g. I and Q, or L+R and L-R). Processes blocks so the inner
// dot products run over contiguous memory and vectorize well.
template <size_t Channels>
class FirDecimator {
 public:
  FirDecimator() = default;
  FirDecimator(std::vector<float> taps, size_t decimation) { configure(std::move(taps), decimation); }

  void configure(std::vector<float> taps, size_t decimation);
  void reset();

  size_t decimation() const { return decimation_; }

  // in[c] points to n samples for channel c. Outputs are appended to out[c].
  // Returns the number of outputs produced.
  size_t process(const std::array<const float*, Channels>& in, size_t n,
                 std::array<std::vector<float>*, Channels> out);

 private:
  std::vector<float> taps_;  // time-reversed
  size_t decimation_ = 1;
  std::array<std::vector<float>, Channels> history_;
  size_t next_ = 0;  // index (in history+input space) of the next output's last sample
};

float dot_product(const float* a, const float* b, size_t n);

extern template class FirDecimator<1>;
extern template class FirDecimator<2>;

}  // namespace terra
