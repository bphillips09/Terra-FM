#include "fftw3.h"

#include <complex>
#include <cstdlib>
#include <memory>
#include <new>

#include "dsp/fft.h"

struct terra_fftwf_plan_s {
  std::unique_ptr<terra::Fft> fft;
  std::complex<float>* in;
  std::complex<float>* out;
  bool inverse;
};

extern "C" {

fftwf_complex* fftwf_alloc_complex(size_t n) {
  // 64-byte alignment, like FFTW, so SIMD loads in callers stay aligned.
  void* p = nullptr;
#if defined(_WIN32)
  p = _aligned_malloc(n * sizeof(fftwf_complex), 64);
#else
  if (posix_memalign(&p, 64, n * sizeof(fftwf_complex)) != 0) p = nullptr;
#endif
  return static_cast<fftwf_complex*>(p);
}

void fftwf_free(void* p) {
#if defined(_WIN32)
  _aligned_free(p);
#else
  std::free(p);
#endif
}

fftwf_plan fftwf_plan_dft_1d(int n, fftwf_complex* in, fftwf_complex* out, int sign,
                             unsigned /*flags*/) {
  if (n <= 0 || !terra::Fft::is_power_of_two(static_cast<size_t>(n))) return nullptr;
  auto* plan = new (std::nothrow) terra_fftwf_plan_s();
  if (!plan) return nullptr;
  plan->fft = std::make_unique<terra::Fft>(static_cast<size_t>(n));
  plan->in = reinterpret_cast<std::complex<float>*>(in);
  plan->out = reinterpret_cast<std::complex<float>*>(out);
  plan->inverse = sign == FFTW_BACKWARD;
  return plan;
}

void fftwf_execute(const fftwf_plan p) {
  if (!p) return;
  if (p->inverse) {
    p->fft->inverse(p->in, p->out);
  } else {
    p->fft->forward(p->in, p->out);
  }
}

void fftwf_destroy_plan(fftwf_plan p) { delete p; }

}  // extern "C"
