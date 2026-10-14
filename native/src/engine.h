#pragma once

#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "audio/audio_output.h"
#include "events.h"
#include "gain/gain_controller.h"
#include "pipeline.h"
#include "sources/iq_source.h"
#include "terra_core.h"
#include "util/ring_buffer.h"

namespace terra {

// Threads:
//   source thread  → IQ ring (lock-free)
//   DSP thread     → pipeline, gain control, periodic events, audio ring
//   audio device   → speaker
// Control calls arrive on the host thread; anything touching DSP state is
// posted to the DSP thread.
class Engine {
 public:
  Engine(terra_event_callback callback, void* user_data);
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  int open(const terra_source_config& config);
  void close();

  int tune(uint32_t frequency_hz, int gain_hint_tenth_db);
  void set_program(int program);
  void set_audio_mode(int mode);
  void set_gain(int mode, int gain_tenth_db);
  void set_ppm(int ppm);
  void set_bias_tee(bool enabled);
  void set_deemphasis_us(int us);
  void set_blend_alignment_ms(int ms);
  void set_hd_level(float level);
  void set_squelch_db(int db);
  void set_volume(float volume);
  void set_audio_enabled(bool enabled);
  void set_spectrum_enabled(bool enabled);
  void set_pcm_callback(terra_pcm_callback callback, void* user_data);

  EventSink& events() { return events_; }

 private:
  void post(std::function<void()> fn);
  void run_posted();
  void dsp_loop();
  void on_source_data(const uint8_t* data, size_t bytes);
  void on_source_state(terra_source_state state, int error, const std::string& message);
  void report_lost(int error, const std::string& message);
  void check_stalled();
  void emit_source_state(terra_source_state state, int error, const std::string& message);
  void emit_device_info();
  void emit_gain();
  void emit_periodic();
  void apply_gain(int gain);
  void retune_dsp(uint32_t frequency_hz, int hint);

  EventSink events_;

  std::mutex control_mutex_;  // open/close/source control
  std::unique_ptr<IqSource> source_;
  SpscRing<uint8_t> iq_ring_;
  std::atomic<bool> source_stopping_{false};
  std::atomic<bool> source_ended_{false};
  std::atomic<bool> source_lossless_{false};
  std::atomic<uint64_t> dropped_bytes_{0};

  // A live source that stops delivering samples is reported lost, once.
  // A tune or gain change pauses the bulk pipe; that pause is not a loss.
  // One quiet stretch is a restarted stream before anything is reported.
  std::atomic<bool> watch_stall_{false};
  std::atomic<bool> lost_reported_{false};
  std::atomic<int64_t> last_data_ms_{0};
  std::atomic<int> stall_timeout_ms_{0};
  std::atomic<int> stall_restarts_{0};
  std::atomic<int64_t> last_restart_ms_{0};
  int tune_failures_ = 0;  // consecutive; guarded by control_mutex_

  std::thread dsp_thread_;
  std::atomic<bool> dsp_running_{false};
  std::mutex wake_mutex_;
  std::condition_variable wake_;
  std::mutex post_mutex_;
  std::vector<std::function<void()>> posted_;

  // DSP-thread state.
  std::unique_ptr<DspPipeline> pipeline_;
  GainController gain_;
  int applied_gain_ = 0x7fffffff;
  uint32_t frequency_hz_ = 0;
  size_t discard_bytes_ = 0;
  uint64_t next_fm_status_ = 0;
  uint64_t next_audio_status_ = 0;
  uint64_t last_drop_log_ = 0;
  bool ended_emitted_ = false;
  std::vector<uint8_t> chunk_;
  std::vector<float> spectrum_;

  // Settings mirrored from the host.
  std::atomic<uint32_t> requested_frequency_{0};
  std::atomic<int> requested_gain_hint_{-1};
  int program_ = 0;
  int audio_mode_ = TERRA_AUDIO_MODE_AUTO;
  int gain_mode_ = TERRA_GAIN_AUTO;
  int manual_gain_ = 300;
  int ppm_ = 0;
  bool bias_tee_ = false;
  int deemphasis_us_ = 75;
  int blend_alignment_ms_ = TERRA_DEFAULT_BLEND_ALIGNMENT_MS;
  float hd_level_ = 1.0f;
  int squelch_db_ = TERRA_DEFAULT_SQUELCH_DB;
  bool spectrum_enabled_ = false;
  std::atomic<bool> audio_enabled_{true};

  AudioOutput audio_;

  std::mutex pcm_mutex_;
  terra_pcm_callback pcm_callback_ = nullptr;
  void* pcm_user_ = nullptr;
};

}  // namespace terra
