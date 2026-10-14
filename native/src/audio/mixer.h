#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "terra_core.h"

namespace terra {

// Chooses between HD and analog audio per sample. The analog stream (one
// output frame per analog frame) is the master clock; HD frames are queued
// and consumed in lockstep, which holds because nrsc5 emits audio at exactly
// 44.1 kHz of IQ time.
//
// In AUTO mode on HD1, dropouts are detected ahead of time in the HD queue
// (nrsc5 inserts silent frames for missing packets) so the crossfade to
// analog completes before the gap is reached.
class AudioMixer {
 public:
  static constexpr size_t kSampleRate = 44100;

  AudioMixer();

  void reset();
  void set_mode(int mode) { mode_ = mode; }
  int mode() const { return mode_; }
  void set_program(int program);
  int program() const { return program_; }
  // > 0 delays HD (deeper HD queue), < 0 delays analog.
  void set_alignment_ms(int ms);
  // HD playback level relative to analog FM. 1 matches FM; stations often
  // master HD quieter, so a little above 1 evens the blend.
  void set_hd_level(float level);

  // Stereo int16 frames from nrsc5 for the selected program.
  void push_hd(const int16_t* frames, size_t frame_count, bool valid);
  // Analog frames (interleaved stereo float). Appends the same number of mixed
  // frames to `out`.
  void mix(const float* analog, size_t frame_count, bool analog_squelched, std::vector<float>& out);

  bool hd_playing() const { return hd_gain_ > 0.5f; }
  bool hd_available() const { return hd_started_; }
  terra_audio_source active_source() const;
  size_t hd_queue_frames() const { return hd_valid_.size() - hd_read_; }

 private:
  void compact();
  bool hd_valid_at(size_t offset) const;
  bool analog_allowed() const;

  int mode_ = TERRA_AUDIO_MODE_AUTO;
  int program_ = 0;

  std::vector<float> hd_frames_;    // interleaved stereo
  std::vector<uint8_t> hd_valid_;   // per frame
  size_t hd_read_ = 0;
  bool hd_started_ = false;
  bool hd_ever_started_ = false;
  size_t good_run_ = 0;
  float hd_gain_ = 0.0f;
  float hd_level_ = 1.0f;
  bool hd_target_ = false;

  std::vector<float> analog_delay_;  // interleaved stereo FIFO
  size_t analog_read_ = 0;
  size_t analog_delay_frames_ = 0;
  size_t hd_delay_frames_ = 0;
  bool last_analog_squelched_ = true;

  size_t start_depth() const { return prefill_frames_ + hd_delay_frames_; }

  size_t prefill_frames_;
  size_t crossfade_frames_;
  size_t recover_frames_;
  size_t max_queue_frames_;
};

}  // namespace terra
