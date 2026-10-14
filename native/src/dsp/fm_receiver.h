#pragma once

#include <complex>
#include <cstdint>
#include <memory>
#include <vector>

#include "dsp/fir.h"
#include "dsp/rds.h"
#include "dsp/resampler.h"

namespace terra {

struct FmStatus {
  float cnr_db = 0.0f;
  float pilot_level = 0.0f;
  bool stereo = false;
  float stereo_blend = 0.0f;
  bool squelched = true;
};

// Broadcast FM receiver for 1,488,375 sps cu8 IQ. Produces interleaved
// stereo float audio at 44.1 kHz and feeds the RDS demodulator.
//
//   IQ 1488375 ─FIR÷3→ 496125 ─FIR÷2 (channel)→ 248062.5 ─discriminator→ MPX
//   MPX ─pilot PLL→ L+R / L−R ─FIR÷5→ 49612.5 ─de-emphasis→ ×8/9 → 44100
class FmReceiver {
 public:
  static constexpr double kIqRate = 1488375.0;
  static constexpr double kMpxRate = kIqRate / 6.0;
  static constexpr double kAudioRate = kMpxRate / 5.0;
  static constexpr double kOutputRate = 44100.0;

  FmReceiver();

  void reset();
  void set_deemphasis_us(int microseconds);
  // Mute below this CNR (dB) and open 2 dB above it. Negative disables muting.
  void set_squelch_db(int threshold_db);
  void set_stereo_enabled(bool enabled) { stereo_enabled_ = enabled; }

  // Converts cu8 bytes (I,Q pairs) and demodulates. Appends interleaved
  // stereo audio at kOutputRate to `audio_out`.
  void process_cu8(const uint8_t* iq, size_t bytes, std::vector<float>& audio_out);
  // Same, for float IQ (interleaved I,Q) already at kIqRate.
  void process_iq(const float* iq, size_t samples, std::vector<float>& audio_out);

  const FmStatus& status() const { return status_; }
  RdsDemodulator& rds() { return rds_; }
  const RdsDemodulator& rds() const { return rds_; }

  // Last MPX block, for tests and diagnostics.
  const std::vector<float>& last_mpx() const { return mpx_; }

 private:
  void demodulate_channel(std::vector<float>& audio_out);

  FirDecimator<2> stage1_;
  FirDecimator<2> stage2_;
  FirDecimator<2> audio_fir_;
  Resampler output_resampler_;

  std::vector<float> in_i_, in_q_, s1_i_, s1_q_, ch_i_, ch_q_;
  std::vector<float> mpx_, diff_in_, sum_out_, diff_out_, stereo_, resampled_;

  std::complex<float> prev_{1.0f, 0.0f};
  double deviation_scale_ = 1.0;

  // 19 kHz band-pass ahead of the pilot PLL (keeps audio out of the loop).
  double bp_b0_ = 0.0, bp_b2_ = 0.0, bp_a1_ = 0.0, bp_a2_ = 0.0;
  double bp_x1_ = 0.0, bp_x2_ = 0.0, bp_y1_ = 0.0, bp_y2_ = 0.0;

  // Pilot PLL.
  double pll_phase_ = 0.0;
  double pll_freq_ = 0.0;
  double pll_w0_ = 0.0;
  float pilot_i_ = 0.0f, pilot_q_ = 0.0f;
  float pilot_level_ = 0.0f;
  bool pilot_locked_ = false;

  // Carrier-to-noise estimate from envelope statistics.
  double env_mean_ = 0.0, env_var_ = 0.0;
  float cnr_db_ = 0.0f;

  float blend_ = 0.0f;
  float squelch_gain_ = 0.0f;
  bool squelched_ = true;
  bool squelch_enabled_ = true;
  // Matches TERRA_DEFAULT_SQUELCH_DB: mute below 7 dB, open above 9 dB.
  float squelch_close_db_ = 7.0f;
  float squelch_open_db_ = 9.0f;
  bool stereo_enabled_ = true;

  float deemph_alpha_ = 0.0f;
  float deemph_l_ = 0.0f, deemph_r_ = 0.0f;

  FmStatus status_;
  RdsDemodulator rds_;
};

}  // namespace terra
