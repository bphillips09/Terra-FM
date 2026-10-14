#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

#include "dsp/resampler.h"
#include "events.h"
#include "util/ring_buffer.h"

namespace terra {

// Speaker output through miniaudio (AAudio/OpenSL ES, CoreAudio, WASAPI,
// PulseAudio/ALSA). The DSP thread writes 44.1 kHz stereo float; the device
// callback resamples to the device rate with a slow trim that keeps the
// buffer depth constant, absorbing SDR vs audio clock drift.
class AudioOutput {
 public:
  explicit AudioOutput(EventSink& events);
  ~AudioOutput();
  AudioOutput(const AudioOutput&) = delete;
  AudioOutput& operator=(const AudioOutput&) = delete;

  bool start();
  void stop();
  bool running() const { return running_.load(); }

  void set_volume(float volume) { volume_.store(volume); }

  // DSP thread. Drops frames when the buffer is full.
  void write(const float* frames, size_t frame_count);
  // DSP thread. Discards buffered audio (e.g. after retune).
  void flush() { flush_requested_.store(true); }

  float buffer_ms() const;
  int underruns() const { return underruns_.load(); }
  int device_sample_rate() const { return device_rate_.load(); }
  // Peak levels since the previous call, dBFS.
  void take_levels(float& left_db, float& right_db);

  // Device thread: fills `frames` interleaved stereo frames.
  void render(float* out, unsigned int frames);

 private:
  struct Device;

  EventSink& events_;
  std::unique_ptr<Device> device_;
  std::mutex control_mutex_;

  SpscRing<float> ring_;
  Resampler resampler_;
  std::vector<float> scratch_in_;
  std::vector<float> pending_;
  size_t pending_pos_ = 0;
  bool prebuffering_ = true;
  double drift_error_ = 0.0;
  float gain_ = 0.0f;

  std::atomic<bool> running_{false};
  std::atomic<bool> flush_requested_{false};
  std::atomic<float> volume_{1.0f};
  std::atomic<int> underruns_{0};
  std::atomic<int> device_rate_{0};
  std::atomic<float> peak_l_{0.0f}, peak_r_{0.0f};

  size_t target_frames_;
};

}  // namespace terra
