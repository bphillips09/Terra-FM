#include "dsp/rds.h"

#include <algorithm>
#include <cmath>

#include "dsp/math.h"

namespace terra {

namespace {

constexpr uint32_t kPoly = 0x5B9;  // x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1
constexpr uint16_t kOffsetA = 0x0FC;
constexpr uint16_t kOffsetB = 0x198;
constexpr uint16_t kOffsetC = 0x168;
constexpr uint16_t kOffsetCp = 0x350;
constexpr uint16_t kOffsetD = 0x1B4;
constexpr double kBitRate = 1187.5;
constexpr double kSubcarrierHz = 57000.0;
constexpr size_t kBasebandDecimation = 16;
constexpr size_t kErrorWindow = 50;
constexpr int kMaxErrorsInWindow = 18;

// Block type of a syndrome: 0=A 1=B 2=C 3=D 4=C', -1 none.
int offset_type(uint16_t s) {
  switch (s) {
    case kOffsetA: return 0;
    case kOffsetB: return 1;
    case kOffsetC: return 2;
    case kOffsetD: return 3;
    case kOffsetCp: return 4;
    default: return -1;
  }
}

int position_of_type(int type) { return type == 4 ? 2 : type; }

void append_utf8(std::string& out, uint32_t cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

// IEC 62106 Annex E (basic G0 set), upper half. 0x20-0x7E are treated as
// ASCII, which matches what North American stations transmit in practice.
constexpr uint16_t kG0Upper[128] = {
    0x00E1, 0x00E0, 0x00E9, 0x00E8, 0x00ED, 0x00EC, 0x00F3, 0x00F2,  // 0x80
    0x00FA, 0x00F9, 0x00D1, 0x00C7, 0x015E, 0x00DF, 0x00A1, 0x0132,
    0x00E2, 0x00E4, 0x00EA, 0x00EB, 0x00EE, 0x00EF, 0x00F4, 0x00F6,  // 0x90
    0x00FB, 0x00FC, 0x00F1, 0x00E7, 0x015F, 0x011F, 0x0131, 0x0133,
    0x00AA, 0x03B1, 0x00A9, 0x2030, 0x011E, 0x011B, 0x0148, 0x0151,  // 0xA0
    0x03C0, 0x20AC, 0x00A3, 0x0024, 0x2190, 0x2191, 0x2192, 0x2193,
    0x00BA, 0x00B9, 0x00B2, 0x00B3, 0x00B1, 0x0130, 0x0144, 0x0171,  // 0xB0
    0x00B5, 0x00BF, 0x00F7, 0x00B0, 0x00BC, 0x00BD, 0x00BE, 0x00A7,
    0x00C1, 0x00C0, 0x00C9, 0x00C8, 0x00CD, 0x00CC, 0x00D3, 0x00D2,  // 0xC0
    0x00DA, 0x00D9, 0x0158, 0x010C, 0x0160, 0x017D, 0x0110, 0x013F,
    0x00C2, 0x00C4, 0x00CA, 0x00CB, 0x00CE, 0x00CF, 0x00D4, 0x00D6,  // 0xD0
    0x00DB, 0x00DC, 0x0159, 0x010D, 0x0161, 0x017E, 0x0111, 0x0140,
    0x00C3, 0x00C5, 0x00C6, 0x0152, 0x0177, 0x00DD, 0x00D5, 0x00D8,  // 0xE0
    0x00DE, 0x014A, 0x0154, 0x0106, 0x015A, 0x0179, 0x0166, 0x00F0,
    0x00E3, 0x00E5, 0x00E6, 0x0153, 0x0175, 0x00FD, 0x00F5, 0x00F8,  // 0xF0
    0x00FE, 0x014B, 0x0155, 0x0107, 0x015B, 0x017A, 0x0167, 0x0020,
};

std::string trim_right(std::string s) {
  while (!s.empty() && s.back() == ' ') s.pop_back();
  return s;
}

}  // namespace

// ---------------------------------------------------------------------------
// Group decoder
// ---------------------------------------------------------------------------

uint16_t RdsGroupDecoder::syndrome(uint32_t block) {
  uint32_t reg = 0;
  for (int i = 25; i >= 0; --i) {
    reg = (reg << 1) | ((block >> i) & 1);
    if (reg & (1u << 10)) reg ^= kPoly;
  }
  return static_cast<uint16_t>(reg & 0x3FF);
}

uint16_t RdsGroupDecoder::checkword(uint16_t info) {
  return syndrome(static_cast<uint32_t>(info) << 10);
}

std::string RdsGroupDecoder::decode_char(uint8_t c) {
  std::string out;
  if (c >= 0x20 && c < 0x7F) {
    out.push_back(static_cast<char>(c));
  } else if (c >= 0x80) {
    append_utf8(out, kG0Upper[c - 0x80]);
  } else {
    out.push_back(' ');
  }
  return out;
}

RdsGroupDecoder::RdsGroupDecoder() {
  // Correctable error patterns: bursts of length 1 and 2 anywhere in the
  // block. Longer bursts are correctable in theory but raise false decodes.
  for (int len = 1; len <= 2; ++len) {
    const uint32_t pattern = (1u << len) - 1;
    for (int shift = 0; shift + len <= 26; ++shift) {
      const uint32_t e = pattern << shift;
      error_table_.emplace(syndrome(e), e);
    }
  }
  recent_.assign(kErrorWindow, false);
  reset();
}

void RdsGroupDecoder::reset() {
  reg_ = 0;
  bits_in_reg_ = 0;
  synced_ = false;
  position_ = 0;
  bit_counter_ = 0;
  total_bits_ = 0;
  last_seen_bit_ = -1;
  last_seen_type_ = -1;
  valid_.fill(false);
  std::fill(recent_.begin(), recent_.end(), false);
  recent_pos_ = 0;
  recent_bad_ = 0;
  recent_count_ = 0;
  data_ = Data{};
  changed_ = false;
  groups_ = 0;
  pi_candidate_ = -1;
  pty_candidate_ = -1;
  pty_hits_ = 0;
  ps_.fill(' ');
  ps_prev_.fill(' ');
  ps_prev_valid_.fill(false);
  ps_valid_.fill(false);
  rt_.fill(' ');
  rt_prev_.fill(' ');
  rt_prev_valid_.fill(false);
  rt_valid_.fill(false);
  rt_ab_ = -1;
}

float RdsGroupDecoder::block_error_rate() const {
  return recent_count_ > 0 ? static_cast<float>(recent_bad_) / static_cast<float>(recent_count_)
                           : 1.0f;
}

void RdsGroupDecoder::note_block(bool ok) {
  const bool was_bad = recent_[recent_pos_];
  if (recent_count_ == static_cast<int>(kErrorWindow)) {
    if (was_bad) --recent_bad_;
  } else {
    ++recent_count_;
  }
  recent_[recent_pos_] = !ok;
  if (!ok) ++recent_bad_;
  recent_pos_ = (recent_pos_ + 1) % kErrorWindow;
}

bool RdsGroupDecoder::correct(uint32_t& block, uint16_t offset) const {
  const uint16_t s = syndrome(block) ^ offset;
  if (s == 0) return true;
  const auto it = error_table_.find(s);
  if (it == error_table_.end()) return false;
  block ^= it->second;
  return true;
}

void RdsGroupDecoder::push_bit(int bit) {
  reg_ = ((reg_ << 1) | static_cast<uint32_t>(bit & 1)) & 0x3FFFFFF;
  ++total_bits_;
  if (bits_in_reg_ < 26) {
    ++bits_in_reg_;
    if (bits_in_reg_ < 26) return;
  }

  if (!synced_) {
    const int type = offset_type(syndrome(reg_));
    if (type < 0) return;
    const auto now = static_cast<int64_t>(total_bits_);
    if (last_seen_bit_ >= 0) {
      const int64_t delta = now - last_seen_bit_;
      if (delta % 26 == 0 && delta <= 26 * 8) {
        const int blocks_apart = static_cast<int>(delta / 26);
        const int expected = (position_of_type(last_seen_type_) + blocks_apart) % 4;
        if (expected == position_of_type(type)) {
          synced_ = true;
          bit_counter_ = 0;
          position_ = position_of_type(type);
          valid_.fill(false);
          on_block(reg_, position_);
          position_ = (position_ + 1) % 4;
          return;
        }
      }
    }
    last_seen_bit_ = now;
    last_seen_type_ = type;
    return;
  }

  if (++bit_counter_ < 26) return;
  bit_counter_ = 0;
  on_block(reg_, position_);
  position_ = (position_ + 1) % 4;
  if (recent_count_ >= 10 && recent_bad_ > kMaxErrorsInWindow) {
    synced_ = false;
    last_seen_bit_ = -1;
    pty_candidate_ = -1;
    pty_hits_ = 0;
    std::fill(recent_.begin(), recent_.end(), false);
    recent_bad_ = 0;
    recent_count_ = 0;
  }
}

void RdsGroupDecoder::on_block(uint32_t block, int position) {
  bool ok = false;
  if (position == 2) {
    uint32_t candidate = block;
    if (correct(candidate, kOffsetC)) {
      ok = true;
      version_b_c_ = false;
      block = candidate;
    } else {
      candidate = block;
      if (correct(candidate, kOffsetCp)) {
        ok = true;
        version_b_c_ = true;
        block = candidate;
      }
    }
  } else {
    static constexpr uint16_t kOffsets[4] = {kOffsetA, kOffsetB, kOffsetC, kOffsetD};
    ok = correct(block, kOffsets[position]);
  }
  note_block(ok);

  if (position == 0) valid_.fill(false);
  blocks_[position] = static_cast<uint16_t>(block >> 10);
  valid_[position] = ok;
  if (position == 3) decode_group();
}

void RdsGroupDecoder::decode_group() {
  ++groups_;
  // PI from block A, or from block C' in version B groups.
  int pi = -1;
  if (valid_[0]) pi = blocks_[0];
  else if (valid_[2] && version_b_c_) pi = blocks_[2];
  if (pi >= 0) {
    if (pi == pi_candidate_ && data_.pi != pi) {
      data_.pi = pi;
      changed_ = true;
    }
    pi_candidate_ = pi;
  }
  if (!valid_[1]) return;

  const uint16_t b = blocks_[1];
  const int group_type = b >> 12;
  const bool version_b = (b >> 11) & 1;
  const bool tp = (b >> 10) & 1;
  const int pty = (b >> 5) & 0x1F;
  if (data_.tp != tp) {
    data_.tp = tp;
    changed_ = true;
  }
  // Three agreeing groups. Two is enough for a 16-bit PI, but a 5-bit PTY
  // collides often when most blocks are errors.
  if (pty == pty_candidate_) {
    if (pty_hits_ < 3) ++pty_hits_;
  } else {
    pty_candidate_ = pty;
    pty_hits_ = 1;
  }
  if (pty_hits_ >= 3 && data_.pty != pty) {
    data_.pty = pty;
    changed_ = true;
  }

  if (group_type == 0) {
    const bool ta = (b >> 4) & 1;
    const bool ms = (b >> 3) & 1;
    if (data_.ta != ta || data_.ms != ms) {
      data_.ta = ta;
      data_.ms = ms;
      changed_ = true;
    }
    if (valid_[3]) decode_ps(b, blocks_[3]);
  } else if (group_type == 2) {
    if (!valid_[3]) return;
    decode_rt(b, blocks_[2], valid_[2] && !version_b, blocks_[3]);
  }
  (void)version_b;
}

void RdsGroupDecoder::decode_ps(uint16_t b, uint16_t d) {
  const int segment = b & 0x3;
  const uint8_t chars[2] = {static_cast<uint8_t>(d >> 8), static_cast<uint8_t>(d & 0xFF)};
  for (int k = 0; k < 2; ++k) {
    const int p = segment * 2 + k;
    // Commit a character only after two identical receptions in a row; this
    // filters the rare undetected block errors.
    if (ps_prev_valid_[p] && ps_prev_[p] == chars[k]) {
      ps_[p] = chars[k];
      ps_valid_[p] = true;
    }
    ps_prev_[p] = chars[k];
    ps_prev_valid_[p] = true;
  }
  if (!std::all_of(ps_valid_.begin(), ps_valid_.end(), [](bool v) { return v; })) return;
  std::string text;
  for (uint8_t c : ps_) text += decode_char(c);
  text = trim_right(text);
  if (!text.empty() && text != data_.ps) {
    data_.ps = text;
    changed_ = true;
  }
}

void RdsGroupDecoder::decode_rt(uint16_t b, uint16_t c, bool c_valid, uint16_t d) {
  const bool version_b = (b >> 11) & 1;
  const int ab = (b >> 4) & 1;
  const int addr = b & 0xF;
  if (rt_ab_ != ab) {
    if (rt_ab_ != -1) {
      rt_.fill(' ');
      rt_valid_.fill(false);
      rt_prev_valid_.fill(false);
    }
    rt_ab_ = ab;
  }

  uint8_t chars[4];
  int count;
  int base;
  if (version_b) {
    chars[0] = static_cast<uint8_t>(d >> 8);
    chars[1] = static_cast<uint8_t>(d & 0xFF);
    count = 2;
    base = addr * 2;
  } else {
    if (!c_valid) return;
    chars[0] = static_cast<uint8_t>(c >> 8);
    chars[1] = static_cast<uint8_t>(c & 0xFF);
    chars[2] = static_cast<uint8_t>(d >> 8);
    chars[3] = static_cast<uint8_t>(d & 0xFF);
    count = 4;
    base = addr * 4;
  }
  for (int k = 0; k < count; ++k) {
    const int p = base + k;
    if (rt_prev_valid_[p] && rt_prev_[p] == chars[k]) {
      rt_[p] = chars[k];
      rt_valid_[p] = true;
    }
    rt_prev_[p] = chars[k];
    rt_prev_valid_[p] = true;
  }

  const int max = version_b ? 32 : 64;
  int end = -1;
  for (int p = 0; p < max; ++p) {
    if (rt_valid_[p] && rt_[p] == 0x0D) {
      end = p;
      break;
    }
  }
  if (end < 0) end = max;
  for (int p = 0; p < end; ++p) {
    if (!rt_valid_[p]) return;
  }
  std::string text;
  for (int p = 0; p < end; ++p) text += decode_char(rt_[p]);
  text = trim_right(text);
  if (!text.empty() && text != data_.rt) {
    data_.rt = text;
    changed_ = true;
  }
}

// ---------------------------------------------------------------------------
// Demodulator
// ---------------------------------------------------------------------------

RdsDemodulator::RdsDemodulator(double mpx_rate) : mpx_rate_(mpx_rate) {
  baseband_rate_ = mpx_rate_ / static_cast<double>(kBasebandDecimation);
  lpf_.configure(design_lowpass(128, 2600.0, mpx_rate_, kaiser_beta_for_attenuation(60.0)),
                 kBasebandDecimation);
  const double w = 2.0 * kPi * kSubcarrierHz / mpx_rate_;
  rot_re_ = std::cos(-w);
  rot_im_ = std::sin(-w);
  samples_per_symbol_ = baseband_rate_ / kBitRate;
  half_len_ = static_cast<int>(samples_per_symbol_ / 2.0);
  mf_hist_.assign(static_cast<size_t>(2 * half_len_ + 1), 0.0f);
  y_hist_.assign(64, 0.0f);
  reset();
}

void RdsDemodulator::reset() {
  nco_re_ = 1.0;
  nco_im_ = 0.0;
  renorm_counter_ = 0;
  lpf_.reset();
  costas_phase_ = 0.0f;
  costas_freq_ = 0.0f;
  agc_ = 1e-3f;
  std::fill(mf_hist_.begin(), mf_hist_.end(), 0.0f);
  mf_pos_ = 0;
  std::fill(y_hist_.begin(), y_hist_.end(), 0.0f);
  y_count_ = 0;
  next_strobe_ = samples_per_symbol_ * 2.0;
  prev_on_ = 0.0f;
  y_agc_ = 1.0f;
  on_energy_ = mid_energy_ = 0.0f;
  prev_symbol_ = 0;
  groups_.reset();
}

void RdsDemodulator::process(const float* mpx, size_t n) {
  mix_i_.resize(n);
  mix_q_.resize(n);
  for (size_t k = 0; k < n; ++k) {
    mix_i_[k] = static_cast<float>(mpx[k] * nco_re_);
    mix_q_[k] = static_cast<float>(mpx[k] * nco_im_);
    const double re = nco_re_ * rot_re_ - nco_im_ * rot_im_;
    const double im = nco_re_ * rot_im_ + nco_im_ * rot_re_;
    nco_re_ = re;
    nco_im_ = im;
    if (++renorm_counter_ >= 1024) {
      renorm_counter_ = 0;
      const double mag = std::sqrt(nco_re_ * nco_re_ + nco_im_ * nco_im_);
      nco_re_ /= mag;
      nco_im_ /= mag;
    }
  }
  bb_i_.clear();
  bb_q_.clear();
  lpf_.process({mix_i_.data(), mix_q_.data()}, n, {&bb_i_, &bb_q_});
  for (size_t k = 0; k < bb_i_.size(); ++k) process_baseband(bb_i_[k], bb_q_[k]);
}

void RdsDemodulator::process_baseband(float i, float q) {
  // Costas loop for BPSK: rotate by -phase, error = sign(I) * Q.
  const float c = std::cos(costas_phase_);
  const float s = std::sin(costas_phase_);
  float ri = i * c + q * s;
  float rq = -i * s + q * c;
  const float mag = std::sqrt(ri * ri + rq * rq);
  agc_ += 0.002f * (mag - agc_);
  const float norm = agc_ > 1e-9f ? 1.0f / agc_ : 0.0f;
  ri *= norm;
  rq *= norm;
  const float err = clamp((ri >= 0 ? 1.0f : -1.0f) * rq, -1.0f, 1.0f);
  // Second-order loop, ~35 Hz bandwidth at the baseband rate: wide enough to
  // pull in a few Hz of subcarrier/sample-clock offset.
  constexpr float kp = 6.0e-3f;
  constexpr float ki = 2.0e-5f;
  costas_freq_ = clamp(costas_freq_ + ki * err, -0.02f, 0.02f);
  costas_phase_ = wrap_phase(costas_phase_ + costas_freq_ + kp * err);

  // Biphase matched filter: (first half-bit) - (second half-bit).
  mf_hist_[mf_pos_] = ri;
  mf_pos_ = (mf_pos_ + 1) % mf_hist_.size();
  const size_t len = mf_hist_.size();
  float y = 0.0f;
  for (int k = 0; k < half_len_; ++k) {
    y += mf_hist_[(mf_pos_ + static_cast<size_t>(k)) % len];                      // older half
    y -= mf_hist_[(mf_pos_ + static_cast<size_t>(k + half_len_ + 1)) % len];     // newer half
  }
  process_symbol_stream(y);
}

void RdsDemodulator::process_symbol_stream(float y) {
  const size_t hist_len = y_hist_.size();
  y_hist_[static_cast<size_t>(y_count_) % hist_len] = y;
  ++y_count_;

  const auto sample_at = [&](double t) {
    const auto i0 = static_cast<int64_t>(std::floor(t));
    const auto f = static_cast<float>(t - static_cast<double>(i0));
    const float a = y_hist_[static_cast<size_t>(i0) % hist_len];
    const float b = y_hist_[static_cast<size_t>(i0 + 1) % hist_len];
    return a + f * (b - a);
  };

  while (next_strobe_ + 1.0 < static_cast<double>(y_count_)) {
    const float on = sample_at(next_strobe_);
    const float mid = sample_at(next_strobe_ - samples_per_symbol_ / 2.0);
    y_agc_ += 0.01f * (std::abs(on) - y_agc_);
    const float scale = y_agc_ > 1e-9f ? 1.0f / y_agc_ : 0.0f;
    const float on_n = on * scale;
    const float mid_n = mid * scale;
    const float prev_n = prev_on_ * scale;

    // Gardner TED: positive error means we sampled early.
    const float err = clamp(mid_n * (prev_n - on_n), -2.0f, 2.0f);
    next_strobe_ += samples_per_symbol_ + 0.08 * static_cast<double>(err);

    // If the half-bit-shifted strobe carries more energy, we locked onto the
    // wrong biphase phase; hop half a symbol.
    on_energy_ += 0.01f * (std::abs(on_n) - on_energy_);
    mid_energy_ += 0.01f * (std::abs(mid_n) - mid_energy_);
    if (mid_energy_ > on_energy_ * 1.25f && on_energy_ > 0.0f) {
      next_strobe_ += samples_per_symbol_ / 2.0;
      std::swap(on_energy_, mid_energy_);
    }

    prev_on_ = on;
    const int symbol = on >= 0.0f ? 1 : 0;
    groups_.push_bit(symbol ^ prev_symbol_);
    prev_symbol_ = symbol;
  }
}

}  // namespace terra
