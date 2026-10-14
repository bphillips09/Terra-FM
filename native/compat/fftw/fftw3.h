/*
 * Minimal FFTW3 (single precision) API used by nrsc5's acquire.c, backed by
 * terra::Fft. Only forward/backward complex DFTs of power-of-two sizes are
 * supported, which is all nrsc5 needs (2048 for FM, 256 for AM).
 */
#ifndef TERRA_COMPAT_FFTW3_H
#define TERRA_COMPAT_FFTW3_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
typedef float fftwf_complex[2];
#else
#include <complex.h>
typedef float _Complex fftwf_complex;
#endif

typedef struct terra_fftwf_plan_s *fftwf_plan;

#define FFTW_FORWARD (-1)
#define FFTW_BACKWARD (+1)
#define FFTW_MEASURE (0U)
#define FFTW_ESTIMATE (1U << 6)

fftwf_complex *fftwf_alloc_complex(size_t n);
void fftwf_free(void *p);
fftwf_plan fftwf_plan_dft_1d(int n, fftwf_complex *in, fftwf_complex *out, int sign,
                             unsigned flags);
void fftwf_execute(const fftwf_plan p);
void fftwf_destroy_plan(fftwf_plan p);

#ifdef __cplusplus
}
#endif

#endif
