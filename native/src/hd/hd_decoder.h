#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <string>

#include "events.h"

struct nrsc5_t;
struct nrsc5_event_t;

namespace terra {

struct HdQuality {
  bool valid = false;
  float mer_lower = 0.0f;
  float mer_upper = 0.0f;
  float ber = 0.0f;
  int64_t updated_us = 0;
};

// nrsc5 in pipe mode: feed cu8 at 1,488,375 sps; events and audio come back
// synchronously on the calling thread.
class HdDecoder {
 public:
  // frames: interleaved stereo int16 at 44.1 kHz. valid=false for the
  // silence nrsc5 inserts when packets are missing.
  using AudioHandler = std::function<void(int program, const int16_t* frames, size_t frame_count,
                                          bool valid)>;

  explicit HdDecoder(EventSink& events);
  ~HdDecoder();
  HdDecoder(const HdDecoder&) = delete;
  HdDecoder& operator=(const HdDecoder&) = delete;

  bool ok() const { return radio_ != nullptr; }

  void set_audio_handler(AudioHandler handler) { audio_handler_ = std::move(handler); }

  // Resets decoder state (call on retune).
  void reset(uint32_t frequency_hz);
  void process_cu8(const uint8_t* iq, size_t bytes);

  bool synced() const { return synced_; }
  const HdQuality& quality() const { return quality_; }
  // Recent fraction of good HDC packets for a program (0..1), -1 if unknown.
  float packet_health(int program) const;
  int64_t last_audio_us(int program) const { return last_audio_us_[clamp_program(program)]; }

 private:
  static void callback(const nrsc5_event_t* evt, void* opaque);
  void handle(const nrsc5_event_t* evt);
  static int clamp_program(int p) { return p < 0 ? 0 : (p > 7 ? 7 : p); }

  EventSink& events_;
  nrsc5_t* radio_ = nullptr;
  AudioHandler audio_handler_;
  bool synced_ = false;
  HdQuality quality_;
  uint32_t frequency_hz_ = 0;
  std::array<float, 8> health_{};
  std::array<int64_t, 8> last_audio_us_{};
};

}  // namespace terra
