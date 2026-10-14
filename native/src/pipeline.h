#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "audio/mixer.h"
#include "dsp/fm_receiver.h"
#include "dsp/signal_meter.h"
#include "events.h"
#include "hd/hd_decoder.h"

namespace terra {

// Everything that turns IQ into audio + metadata, without threads. The engine
// drives it from its DSP thread; tests drive it directly from recordings.
class DspPipeline {
 public:
  explicit DspPipeline(EventSink& events);

  void reset(uint32_t frequency_hz);
  // cu8 IQ at TERRA_IQ_SAMPLE_RATE (even byte count).
  void process(const uint8_t* iq, size_t bytes);

  // Mixed audio produced by the last process() call (interleaved stereo).
  const std::vector<float>& output() const { return output_; }
  // Analog audio produced by the last process() call (before mixing).
  const std::vector<float>& analog_output() const { return analog_; }

  void set_program(int program) { mixer_.set_program(program); }
  void set_audio_mode(int mode) { mixer_.set_mode(mode); }
  void set_blend_alignment_ms(int ms) { mixer_.set_alignment_ms(ms); }
  void set_hd_level(float level) { mixer_.set_hd_level(level); }
  void set_deemphasis_us(int us) { fm_.set_deemphasis_us(us); }
  void set_squelch_db(int db) { fm_.set_squelch_db(db); }
  void set_spectrum_enabled(bool enabled) { meter_.set_spectrum_enabled(enabled); }

  HdDecoder& hd() { return hd_; }
  FmReceiver& fm() { return fm_; }
  SignalMeter& meter() { return meter_; }
  AudioMixer& mixer() { return mixer_; }
  const HdDecoder& hd() const { return hd_; }
  const FmReceiver& fm() const { return fm_; }
  const AudioMixer& mixer() const { return mixer_; }

  // IQ samples processed since the last reset (stream time).
  uint64_t samples() const { return samples_; }
  double seconds() const { return static_cast<double>(samples_) / TERRA_IQ_SAMPLE_RATE; }
  // HD audio frames received per program since reset.
  uint64_t hd_frames(int program) const { return hd_frames_[program & 7]; }

 private:
  SignalMeter meter_;
  HdDecoder hd_;
  FmReceiver fm_;
  AudioMixer mixer_;
  std::vector<float> analog_;
  std::vector<float> output_;
  uint64_t samples_ = 0;
  std::array<uint64_t, 8> hd_frames_{};
};

}  // namespace terra
