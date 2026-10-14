#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "dsp/fir.h"

namespace terra {

// RDS/RBDS group-layer decoder: block sync (with burst error correction),
// PI, PTY, TP/TA/MS, Program Service and RadioText.
class RdsGroupDecoder {
 public:
  struct Data {
    int pi = -1;
    int pty = -1;
    bool tp = false;
    bool ta = false;
    bool ms = false;
    std::string ps;  // UTF-8, empty until complete
    std::string rt;  // UTF-8, empty until complete
  };

  RdsGroupDecoder();
  void reset();

  void push_bit(int bit);

  bool synced() const { return synced_; }
  float block_error_rate() const;
  const Data& data() const { return data_; }
  // True (once) after any field in data() changed.
  bool take_changed() {
    const bool c = changed_;
    changed_ = false;
    return c;
  }
  uint64_t groups_decoded() const { return groups_; }

  static uint16_t syndrome(uint32_t block26);
  static uint16_t checkword(uint16_t info);  // for tests / encoders
  static std::string decode_char(uint8_t c);

 private:
  void on_block(uint32_t block, int position);
  void decode_group();
  void decode_ps(uint16_t b, uint16_t d);
  void decode_rt(uint16_t b, uint16_t c, bool c_valid, uint16_t d);
  bool correct(uint32_t& block, uint16_t offset) const;
  void note_block(bool ok);

  uint32_t reg_ = 0;
  int bits_in_reg_ = 0;
  bool synced_ = false;
  int position_ = 0;      // expected block index 0..3 when synced
  int bit_counter_ = 0;   // bits since last block boundary when synced
  uint64_t total_bits_ = 0;
  // Acquisition: last valid-syndrome sighting.
  int64_t last_seen_bit_ = -1;
  int last_seen_type_ = -1;

  std::array<uint16_t, 4> blocks_{};
  std::array<bool, 4> valid_{};
  bool version_b_c_ = false;  // block C carried C' offset

  std::vector<bool> recent_;  // sliding window of block results
  size_t recent_pos_ = 0;
  int recent_bad_ = 0;
  int recent_count_ = 0;

  std::unordered_map<uint16_t, uint32_t> error_table_;

  Data data_;
  bool changed_ = false;
  uint64_t groups_ = 0;
  int pi_candidate_ = -1;
  // PTY is 5 bits and sits in every group, so a single corrected block on a
  // weak carrier is often a different category. Commit only after the same
  // code arrives on several groups; the last committed value stays through
  // a sync loss.
  int pty_candidate_ = -1;
  int pty_hits_ = 0;

  std::array<uint8_t, 8> ps_{};
  std::array<uint8_t, 8> ps_prev_{};
  std::array<bool, 8> ps_prev_valid_{};
  std::array<bool, 8> ps_valid_{};

  std::array<uint8_t, 64> rt_{};
  std::array<uint8_t, 64> rt_prev_{};
  std::array<bool, 64> rt_prev_valid_{};
  std::array<bool, 64> rt_valid_{};
  int rt_ab_ = -1;
};

// RDS physical layer: 57 kHz BPSK (biphase) demodulation from the FM
// multiplex, feeding RdsGroupDecoder.
class RdsDemodulator {
 public:
  explicit RdsDemodulator(double mpx_rate);
  void reset();
  void process(const float* mpx, size_t n);

  RdsGroupDecoder& groups() { return groups_; }
  const RdsGroupDecoder& groups() const { return groups_; }

 private:
  void process_baseband(float i, float q);
  void process_symbol_stream(float y);

  double mpx_rate_;
  double baseband_rate_;
  // 57 kHz mixer (rotating phasor).
  double nco_re_ = 1.0, nco_im_ = 0.0, rot_re_ = 1.0, rot_im_ = 0.0;
  int renorm_counter_ = 0;
  FirDecimator<2> lpf_;
  std::vector<float> mix_i_, mix_q_, bb_i_, bb_q_;
  // Costas loop.
  float costas_phase_ = 0.0f, costas_freq_ = 0.0f, agc_ = 1e-3f;
  // Biphase matched filter (running half-bit sums).
  std::vector<float> mf_hist_;
  size_t mf_pos_ = 0;
  int half_len_ = 6;
  // Gardner timing recovery on the matched-filter output.
  std::vector<float> y_hist_;  // recent matched filter outputs (ring)
  int64_t y_count_ = 0;
  double samples_per_symbol_ = 13.0;
  double next_strobe_ = 0.0;
  float prev_on_ = 0.0f;
  float y_agc_ = 1.0f;
  float on_energy_ = 0.0f, mid_energy_ = 0.0f;
  int prev_symbol_ = 0;

  RdsGroupDecoder groups_;
};

}  // namespace terra
