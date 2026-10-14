#include "dsp/fm_receiver.h"

#include <algorithm>
#include <cmath>

#include "dsp/math.h"

namespace terra {

namespace {

constexpr double kPeakDeviationHz = 75000.0;
constexpr double kPilotHz = 19000.0;
// Pilot loop: ~400 Hz arm filter, ~30 Hz second-order loop.
constexpr float kPilotArmAlpha = 0.01f;
constexpr double kPilotKp = 3.2e-4;
constexpr double kPilotKi = 5.2e-8;
constexpr double kPilotBandpassQ = 10.0;
constexpr float kPilotLockOn = 0.030f;   // coherent pilot amplitude (nominal ~0.09)
constexpr float kPilotLockOff = 0.018f;
// Stereo blend and squelch thresholds on the envelope CNR estimate.
constexpr float kBlendLowDb = 16.0f;
constexpr float kBlendHighDb = 28.0f;
constexpr float kSquelchHysteresisDb = 2.0f;
constexpr float kOutputGain = 1.0f;

float soft_clip(float x) {
  // Transparent below ~0.8, smoothly saturating to ±1.
  const float a = std::abs(x);
  if (a <= 0.8f) return x;
  const float over = (a - 0.8f) / 0.2f;
  const float y = 0.8f + 0.2f * std::tanh(over);
  return x < 0 ? -y : y;
}

}  // namespace

FmReceiver::FmReceiver() : rds_(kMpxRate) {
  const double beta = kaiser_beta_for_attenuation(60.0);
  stage1_.configure(design_lowpass(28, 248000.0, kIqRate, beta), 3);
  stage2_.configure(design_lowpass(64, 118000.0, kIqRate / 3.0, kaiser_beta_for_attenuation(55.0)), 2);
  audio_fir_.configure(design_lowpass(192, 16000.0, kMpxRate, kaiser_beta_for_attenuation(70.0)), 5);
  output_resampler_.configure(kAudioRate, kOutputRate, 2, 32, 256);
  deviation_scale_ = kMpxRate / (2.0 * kPi * kPeakDeviationHz);
  pll_w0_ = 2.0 * kPi * kPilotHz / kMpxRate;
  {
    // RBJ band-pass, 0 dB peak, Q = 10 (~1.9 kHz wide). Zero phase at 19 kHz;
    // the slope (~1 mrad/Hz) is negligible for pilot frequency errors.
    const double alpha = std::sin(pll_w0_) / (2.0 * kPilotBandpassQ);
    const double a0 = 1.0 + alpha;
    bp_b0_ = alpha / a0;
    bp_b2_ = -alpha / a0;
    bp_a1_ = -2.0 * std::cos(pll_w0_) / a0;
    bp_a2_ = (1.0 - alpha) / a0;
  }
  set_deemphasis_us(75);
  reset();
}

void FmReceiver::reset() {
  stage1_.reset();
  stage2_.reset();
  audio_fir_.reset();
  output_resampler_.reset();
  prev_ = {1.0f, 0.0f};
  pll_phase_ = 0.0;
  pll_freq_ = 0.0;
  bp_x1_ = bp_x2_ = bp_y1_ = bp_y2_ = 0.0;
  pilot_i_ = pilot_q_ = 0.0f;
  pilot_level_ = 0.0f;
  pilot_locked_ = false;
  env_mean_ = env_var_ = 0.0;
  cnr_db_ = 0.0f;
  blend_ = 0.0f;
  // Stay muted across a retune unless squelch is off, so tuning noise
  // doesn't play. The threshold itself survives reset.
  squelched_ = squelch_enabled_;
  squelch_gain_ = squelch_enabled_ ? 0.0f : 1.0f;
  deemph_l_ = deemph_r_ = 0.0f;
  status_ = FmStatus{};
  status_.squelched = squelched_;
  rds_.reset();
}

void FmReceiver::set_squelch_db(int threshold_db) {
  if (threshold_db < 0) {
    squelch_enabled_ = false;
    squelched_ = false;
    return;
  }
  squelch_enabled_ = true;
  squelch_close_db_ = clamp(static_cast<float>(threshold_db), 0.0f, 60.0f);
  squelch_open_db_ = squelch_close_db_ + kSquelchHysteresisDb;
  if (cnr_db_ > squelch_open_db_) squelched_ = false;
  else if (cnr_db_ < squelch_close_db_) squelched_ = true;
}

void FmReceiver::set_deemphasis_us(int microseconds) {
  if (microseconds <= 0) {
    deemph_alpha_ = 0.0f;  // disabled
    return;
  }
  const double tau = microseconds * 1e-6;
  deemph_alpha_ = static_cast<float>(std::exp(-1.0 / (kAudioRate * tau)));
}

void FmReceiver::process_cu8(const uint8_t* iq, size_t bytes, std::vector<float>& audio_out) {
  const size_t samples = bytes / 2;
  in_i_.resize(samples);
  in_q_.resize(samples);
  constexpr float kScale = 1.0f / 127.5f;
  for (size_t k = 0; k < samples; ++k) {
    in_i_[k] = (static_cast<float>(iq[2 * k]) - 127.5f) * kScale;
    in_q_[k] = (static_cast<float>(iq[2 * k + 1]) - 127.5f) * kScale;
  }
  s1_i_.clear();
  s1_q_.clear();
  stage1_.process({in_i_.data(), in_q_.data()}, samples, {&s1_i_, &s1_q_});
  ch_i_.clear();
  ch_q_.clear();
  stage2_.process({s1_i_.data(), s1_q_.data()}, s1_i_.size(), {&ch_i_, &ch_q_});
  demodulate_channel(audio_out);
}

void FmReceiver::process_iq(const float* iq, size_t samples, std::vector<float>& audio_out) {
  in_i_.resize(samples);
  in_q_.resize(samples);
  for (size_t k = 0; k < samples; ++k) {
    in_i_[k] = iq[2 * k];
    in_q_[k] = iq[2 * k + 1];
  }
  s1_i_.clear();
  s1_q_.clear();
  stage1_.process({in_i_.data(), in_q_.data()}, samples, {&s1_i_, &s1_q_});
  ch_i_.clear();
  ch_q_.clear();
  stage2_.process({s1_i_.data(), s1_q_.data()}, s1_i_.size(), {&ch_i_, &ch_q_});
  demodulate_channel(audio_out);
}

void FmReceiver::demodulate_channel(std::vector<float>& audio_out) {
  const size_t n = ch_i_.size();
  if (n == 0) return;
  mpx_.resize(n);
  diff_in_.resize(n);

  constexpr double kEnvAlpha = 1.0 / 8192.0;  // ~33 ms at the MPX rate
  double pilot_sum = 0.0;
  for (size_t k = 0; k < n; ++k) {
    const std::complex<float> z(ch_i_[k], ch_q_[k]);

    // Envelope statistics -> CNR. For a constant-envelope FM carrier,
    // var(|z|^2) ~= 2 A^2 sigma^2, so CNR ~= 2 mean^2 / var.
    const double p = static_cast<double>(std::norm(z));
    env_mean_ += kEnvAlpha * (p - env_mean_);
    const double dev = p - env_mean_;
    env_var_ += kEnvAlpha * (dev * dev - env_var_);

    // Phase-difference discriminator.
    const std::complex<float> d = z * std::conj(prev_);
    prev_ = z;
    const float mpx = static_cast<float>(std::atan2(d.imag(), d.real()) * deviation_scale_);
    mpx_[k] = mpx;

    // Pilot PLL on the band-passed MPX: lock theta so the pilot ~= A cos(theta).
    const double bp = bp_b0_ * mpx + bp_b2_ * bp_x2_ - bp_a1_ * bp_y1_ - bp_a2_ * bp_y2_;
    bp_x2_ = bp_x1_;
    bp_x1_ = mpx;
    bp_y2_ = bp_y1_;
    bp_y1_ = bp;
    const auto pilot = static_cast<float>(bp);
    const auto c = static_cast<float>(std::cos(pll_phase_));
    const auto s = static_cast<float>(std::sin(pll_phase_));
    pilot_i_ += kPilotArmAlpha * (pilot * c - pilot_i_);
    pilot_q_ += kPilotArmAlpha * (-pilot * s - pilot_q_);
    pilot_sum += pilot_i_;
    const float mag = std::sqrt(pilot_i_ * pilot_i_ + pilot_q_ * pilot_q_);
    const double err = mag > 1e-6f ? std::atan2(pilot_q_, pilot_i_) : 0.0;
    pll_freq_ = clamp(pll_freq_ + kPilotKi * err, -2e-3, 2e-3);
    pll_phase_ += pll_w0_ + pll_freq_ + kPilotKp * err;
    if (pll_phase_ > kPi) pll_phase_ -= 2.0 * kPi;

    // Broadcast pilot is sin(wt), so theta = wt - pi/2 and the L-R carrier
    // sin(2wt) equals -sin(2 theta). The 2x restores the DSB-SC amplitude.
    const float ref38 = -2.0f * s * c;
    diff_in_[k] = 2.0f * mpx * ref38;
  }

  // Pilot level = 2 * coherent in-phase component (A/2 after mixing).
  pilot_level_ = std::max(0.0f, static_cast<float>(2.0 * pilot_sum / static_cast<double>(n)));
  if (!pilot_locked_ && pilot_level_ > kPilotLockOn) pilot_locked_ = true;
  if (pilot_locked_ && pilot_level_ < kPilotLockOff) pilot_locked_ = false;

  if (env_var_ > 1e-30 && env_mean_ > 0) {
    cnr_db_ = db_from_power(2.0 * env_mean_ * env_mean_ / env_var_);
  } else {
    cnr_db_ = env_mean_ > 0 ? 60.0f : 0.0f;
  }
  cnr_db_ = clamp(cnr_db_, -10.0f, 60.0f);
  if (!squelch_enabled_) {
    squelched_ = false;
  } else {
    if (squelched_ && cnr_db_ > squelch_open_db_) squelched_ = false;
    if (!squelched_ && cnr_db_ < squelch_close_db_) squelched_ = true;
  }

  rds_.process(mpx_.data(), n);

  sum_out_.clear();
  diff_out_.clear();
  audio_fir_.process({mpx_.data(), diff_in_.data()}, n, {&sum_out_, &diff_out_});

  const float target_blend =
      (stereo_enabled_ && pilot_locked_)
          ? clamp((cnr_db_ - kBlendLowDb) / (kBlendHighDb - kBlendLowDb), 0.0f, 1.0f)
          : 0.0f;
  const float target_squelch = squelched_ ? 0.0f : 1.0f;
  constexpr float kBlendAlpha = 1.0f / 16000.0f;   // ~0.3 s at the audio rate
  constexpr float kSquelchAlpha = 1.0f / 1500.0f;  // ~30 ms

  const size_t m = sum_out_.size();
  stereo_.resize(2 * m);
  for (size_t k = 0; k < m; ++k) {
    blend_ += kBlendAlpha * (target_blend - blend_);
    squelch_gain_ += kSquelchAlpha * (target_squelch - squelch_gain_);
    const float sum = sum_out_[k];
    const float side = diff_out_[k] * blend_;
    float left = sum + side;
    float right = sum - side;
    if (deemph_alpha_ > 0.0f) {
      deemph_l_ = left + deemph_alpha_ * (deemph_l_ - left);
      deemph_r_ = right + deemph_alpha_ * (deemph_r_ - right);
      left = deemph_l_;
      right = deemph_r_;
    }
    stereo_[2 * k] = soft_clip(left * kOutputGain * squelch_gain_);
    stereo_[2 * k + 1] = soft_clip(right * kOutputGain * squelch_gain_);
  }
  output_resampler_.process(stereo_.data(), m, audio_out);

  status_.cnr_db = cnr_db_;
  status_.pilot_level = pilot_level_;
  status_.stereo = pilot_locked_;
  status_.stereo_blend = blend_;
  status_.squelched = squelched_;
}

}  // namespace terra
