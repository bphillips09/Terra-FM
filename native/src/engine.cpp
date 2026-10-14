#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>

#include "sources/file_source.h"
#include "sources/rtlsdr_source.h"
#include "sources/rtltcp_source.h"

namespace terra {

namespace {
constexpr size_t kIqRingBytes = size_t{1} << 22;  // ~1.4 s
constexpr size_t kChunkBytes = 32768;             // ~11 ms
constexpr double kRetuneDiscardSeconds = 0.15;    // in-flight USB buffers + PLL settle
constexpr double kStatusIntervalSeconds = 0.25;
constexpr int kMaxTuneFailures = 3;

uint64_t seconds_to_samples(double s) { return static_cast<uint64_t>(s * TERRA_IQ_SAMPLE_RATE); }

int64_t steady_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

Engine::Engine(terra_event_callback callback, void* user_data)
    : iq_ring_(kIqRingBytes), audio_(events_) {
  events_.set_handler([callback, user_data](terra_event* event) {
    if (callback) callback(user_data, event);
    else terra_event_free(event);
  });
  pipeline_ = std::make_unique<DspPipeline>(events_);
  pipeline_->set_blend_alignment_ms(blend_alignment_ms_);
  pipeline_->set_squelch_db(squelch_db_);
  chunk_.resize(kChunkBytes);
  dsp_running_ = true;
  dsp_thread_ = std::thread([this] { dsp_loop(); });
}

Engine::~Engine() {
  close();
  dsp_running_ = false;
  wake_.notify_all();
  if (dsp_thread_.joinable()) dsp_thread_.join();
  audio_.stop();
  // Drop the handler so late emits cannot reach a dead host.
  events_.set_handler(nullptr);
}

// ---------------------------------------------------------------------------
// Host thread
// ---------------------------------------------------------------------------

void Engine::post(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lock(post_mutex_);
    posted_.push_back(std::move(fn));
  }
  wake_.notify_one();
}

int Engine::open(const terra_source_config& config) {
  close();
  std::lock_guard<std::mutex> lock(control_mutex_);
  emit_source_state(TERRA_SOURCE_STATE_OPENING, 0, "");

  std::unique_ptr<IqSource> source;
  switch (config.kind) {
    case TERRA_SOURCE_RTLSDR_FD:
      source.reset(RtlSdrSource::from_fd(events_, config.fd));
      break;
    case TERRA_SOURCE_RTLSDR_INDEX:
      source.reset(RtlSdrSource::from_index(events_, config.device_index));
      break;
    case TERRA_SOURCE_RTL_TCP:
      source = std::make_unique<RtlTcpSource>(events_, config.host ? config.host : "127.0.0.1",
                                              config.port);
      break;
    case TERRA_SOURCE_FILE:
      if (!config.path) {
        emit_source_state(TERRA_SOURCE_STATE_ERROR, -1, "no file path");
        return -1;
      }
      source = std::make_unique<FileSource>(events_, config.path, config.realtime != 0,
                                            config.loop != 0);
      break;
    default:
      emit_source_state(TERRA_SOURCE_STATE_ERROR, -1, "unknown source kind");
      return -1;
  }

  std::string error;
  if (!source->open(error)) {
    events_.log(TERRA_LOG_ERROR, "engine", "open failed: %s", error.c_str());
    emit_source_state(TERRA_SOURCE_STATE_ERROR, -2, error);
    return -2;
  }

  source_ = std::move(source);
  source_stopping_ = false;
  source_ended_ = false;
  source_lossless_ = source_->lossless();
  lost_reported_ = false;
  stall_restarts_.store(0, std::memory_order_relaxed);
  last_restart_ms_.store(0, std::memory_order_relaxed);
  tune_failures_ = 0;
  last_data_ms_ = steady_ms();
  stall_timeout_ms_ = source_->stall_timeout_ms();
  if (source_->tunable()) {
    source_->set_ppm(ppm_);
    if (source_->info().supports_bias_tee) source_->set_bias_tee(bias_tee_);
  }

  const std::vector<int> gains = source_->info().gains;
  const bool tunable = source_->tunable();
  const uint32_t frequency = requested_frequency_.load();
  const int hint = requested_gain_hint_.load();
  if (tunable && frequency != 0) source_->set_frequency(frequency);
  post([this, gains, tunable, frequency, hint] {
    gain_.set_available_gains(gains);
    gain_.set_mode(gain_mode_, manual_gain_);
    ended_emitted_ = false;
    dropped_bytes_ = 0;
    last_drop_log_ = 0;
    iq_ring_.clear();
    if (tunable && frequency != 0) {
      retune_dsp(frequency, hint);
    } else {
      pipeline_->reset(frequency);
      frequency_hz_ = frequency;
      audio_.flush();
      if (frequency != 0) {
        EventBuilder b(TERRA_EVENT_TUNED);
        b.ev().u.tuned.frequency_hz = frequency;
        events_.emit(b);
      }
    }
  });

  emit_device_info();
  if (!source_->start([this](const uint8_t* d, size_t n) { on_source_data(d, n); },
                      [this](terra_source_state s, int e, const std::string& m) {
                        on_source_state(s, e, m);
                      })) {
    source_.reset();
    emit_source_state(TERRA_SOURCE_STATE_ERROR, -3, "failed to start stream");
    return -3;
  }
  emit_source_state(TERRA_SOURCE_STATE_STREAMING, 0, "");
  last_data_ms_ = steady_ms();
  watch_stall_ = tunable;
  if (audio_enabled_) audio_.start();
  return 0;
}

void Engine::close() {
  source_stopping_ = true;
  watch_stall_ = false;
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (!source_) return;
  source_->stop();
  source_.reset();
  audio_.stop();
  emit_source_state(TERRA_SOURCE_STATE_CLOSED, 0, "");
}

int Engine::tune(uint32_t frequency_hz, int hint) {
  requested_frequency_ = frequency_hz;
  requested_gain_hint_ = hint;
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (!source_) return 0;
  if (!source_->tunable()) {
    post([this, frequency_hz] {
      frequency_hz_ = frequency_hz;
      EventBuilder b(TERRA_EVENT_TUNED);
      b.ev().u.tuned.frequency_hz = frequency_hz;
      events_.emit(b);
    });
    return 0;
  }
  if (!source_->set_frequency(frequency_hz)) {
    events_.log(TERRA_LOG_ERROR, "engine", "set_frequency(%u) failed", frequency_hz);
    if (source_->device_gone()) {
      report_lost(-4, "The receiver disconnected");
    } else if (++tune_failures_ >= kMaxTuneFailures) {
      report_lost(-5, "The tuner stopped responding");
    } else {
      // The attempt paused the sample pipe. Don't count that as silence.
      last_data_ms_.store(steady_ms(), std::memory_order_release);
    }
    return -1;
  }
  tune_failures_ = 0;
  last_data_ms_.store(steady_ms(), std::memory_order_release);
  post([this, frequency_hz, hint] { retune_dsp(frequency_hz, hint); });
  return 0;
}

void Engine::set_program(int program) {
  post([this, program] {
    program_ = program;
    pipeline_->set_program(program);
    next_audio_status_ = 0;
  });
}

void Engine::set_audio_mode(int mode) {
  post([this, mode] {
    audio_mode_ = mode;
    pipeline_->set_audio_mode(mode);
    next_audio_status_ = 0;
  });
}

void Engine::set_gain(int mode, int gain_tenth_db) {
  post([this, mode, gain_tenth_db] {
    gain_mode_ = mode;
    manual_gain_ = gain_tenth_db;
    gain_.set_mode(mode, gain_tenth_db);
    const int g = gain_.begin(mode == TERRA_GAIN_MANUAL ? gain_tenth_db : -1,
                              static_cast<int64_t>(pipeline_->seconds() * 1e6));
    if (g != GainController::kNoChange) apply_gain(g);
    emit_gain();
  });
}

void Engine::set_ppm(int ppm) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  ppm_ = ppm;
  if (!source_) return;
  const bool ok = source_->set_ppm(ppm);
  if (!ok && source_->device_gone()) return;
  // The correction write pauses samples. Don't count that as silence.
  last_data_ms_.store(steady_ms(), std::memory_order_release);
}

void Engine::set_bias_tee(bool enabled) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  bias_tee_ = enabled;
  if (!source_) return;
  if (!source_->set_bias_tee(enabled) && enabled) {
    events_.log(TERRA_LOG_WARN, "engine", "bias tee not supported by this source");
  }
  if (!source_->device_gone()) last_data_ms_.store(steady_ms(), std::memory_order_release);
}

void Engine::set_deemphasis_us(int us) {
  post([this, us] {
    deemphasis_us_ = us;
    pipeline_->set_deemphasis_us(us);
  });
}

void Engine::set_blend_alignment_ms(int ms) {
  post([this, ms] {
    blend_alignment_ms_ = ms;
    pipeline_->set_blend_alignment_ms(ms);
  });
}

void Engine::set_hd_level(float level) {
  post([this, level] {
    hd_level_ = level;
    pipeline_->set_hd_level(level);
  });
}

void Engine::set_squelch_db(int db) {
  if (db < 0) db = TERRA_SQUELCH_OFF;
  else db = std::clamp(db, TERRA_SQUELCH_MIN_DB, TERRA_SQUELCH_MAX_DB);
  post([this, db] {
    squelch_db_ = db;
    pipeline_->set_squelch_db(db);
  });
}

void Engine::set_volume(float volume) { audio_.set_volume(std::clamp(volume, 0.0f, 2.0f)); }

void Engine::set_audio_enabled(bool enabled) {
  audio_enabled_ = enabled;
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (enabled && source_) audio_.start();
  else if (!enabled) audio_.stop();
}

void Engine::set_spectrum_enabled(bool enabled) {
  post([this, enabled] {
    spectrum_enabled_ = enabled;
    pipeline_->set_spectrum_enabled(enabled);
  });
}

void Engine::set_pcm_callback(terra_pcm_callback callback, void* user_data) {
  std::lock_guard<std::mutex> lock(pcm_mutex_);
  pcm_callback_ = callback;
  pcm_user_ = user_data;
}

// ---------------------------------------------------------------------------
// Source thread
// ---------------------------------------------------------------------------

void Engine::on_source_data(const uint8_t* data, size_t bytes) {
  if (source_stopping_) return;
  const int64_t now = steady_ms();
  last_data_ms_.store(now, std::memory_order_release);
  // A restart that is followed by a full timeout of samples was a hiccup.
  if (stall_restarts_.load(std::memory_order_relaxed) != 0) {
    const int64_t restarted = last_restart_ms_.load(std::memory_order_relaxed);
    const int timeout = stall_timeout_ms_.load(std::memory_order_relaxed);
    if (restarted != 0 && now - restarted >= timeout)
      stall_restarts_.store(0, std::memory_order_relaxed);
  }
  bytes &= ~size_t{1};
  if (!source_lossless_) {
    // All or nothing keeps I/Q pairs aligned.
    if (iq_ring_.free_space() >= bytes) iq_ring_.write(data, bytes);
    else dropped_bytes_ += bytes;
  } else {
    size_t done = 0;
    while (done < bytes && !source_stopping_) {
      const size_t n = std::min(bytes - done, iq_ring_.free_space() & ~size_t{1});
      if (n == 0) {
        wake_.notify_one();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }
      done += iq_ring_.write(data + done, n);
    }
  }
  wake_.notify_one();
}

void Engine::on_source_state(terra_source_state state, int error, const std::string& message) {
  if (state == TERRA_SOURCE_STATE_ENDED) {
    source_ended_ = true;
    wake_.notify_one();
    return;
  }
  if (state == TERRA_SOURCE_STATE_LOST) {
    report_lost(error, message);
    return;
  }
  emit_source_state(state, error, message);
}

// Whichever notices first (the read thread ending, a failed control call, or
// the stall watchdog) reports the loss; the others stay quiet.
void Engine::report_lost(int error, const std::string& message) {
  if (source_stopping_ || lost_reported_.exchange(true)) return;
  watch_stall_ = false;
  events_.log(TERRA_LOG_ERROR, "engine", "receiver lost: %s", message.c_str());
  emit_source_state(TERRA_SOURCE_STATE_LOST, error, message);
}

void Engine::check_stalled() {
  if (!watch_stall_ || source_stopping_ || source_ended_) return;
  const int timeout = stall_timeout_ms_.load(std::memory_order_relaxed);
  int64_t now = steady_ms();
  int64_t idle = now - last_data_ms_.load(std::memory_order_acquire);
  if (idle < timeout) return;

  // set_frequency / set_gain hold this mutex and, on macOS, pause the bulk
  // reader for the whole call. The tuner is still connected.
  std::unique_lock<std::mutex> lock(control_mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    last_data_ms_.store(steady_ms(), std::memory_order_release);
    return;
  }

  now = steady_ms();
  idle = now - last_data_ms_.load(std::memory_order_acquire);
  if (idle < timeout) return;

  // One quiet stretch: the pipe is stuck, the device is still open. Restart
  // it. A second stretch with no samples in between is a real loss.
  if (stall_restarts_.load(std::memory_order_relaxed) < 1 && source_ && source_->restart()) {
    const int64_t restarted = steady_ms();
    stall_restarts_.store(1, std::memory_order_relaxed);
    last_restart_ms_.store(restarted, std::memory_order_relaxed);
    last_data_ms_.store(restarted, std::memory_order_release);
    lock.unlock();
    events_.log(TERRA_LOG_WARN, "engine", "no samples for %lld ms; restarted the stream",
                static_cast<long long>(idle));
    return;
  }

  lock.unlock();
  events_.log(TERRA_LOG_WARN, "engine", "no samples for %lld ms", static_cast<long long>(idle));
  report_lost(-6, "The receiver stopped sending samples");
}

// ---------------------------------------------------------------------------
// DSP thread
// ---------------------------------------------------------------------------

void Engine::run_posted() {
  std::vector<std::function<void()>> work;
  {
    std::lock_guard<std::mutex> lock(post_mutex_);
    work.swap(posted_);
  }
  for (auto& fn : work) fn();
}

void Engine::retune_dsp(uint32_t frequency_hz, int hint) {
  iq_ring_.clear();
  discard_bytes_ = static_cast<size_t>(kRetuneDiscardSeconds * TERRA_IQ_SAMPLE_RATE) * 2;
  frequency_hz_ = frequency_hz;
  pipeline_->reset(frequency_hz);
  audio_.flush();
  next_fm_status_ = 0;
  next_audio_status_ = 0;

  const int g = gain_.begin(hint, 0);
  if (g != GainController::kNoChange) apply_gain(g);

  EventBuilder b(TERRA_EVENT_TUNED);
  b.ev().u.tuned.frequency_hz = frequency_hz;
  events_.emit(b);
  emit_gain();
}

void Engine::apply_gain(int gain) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (!source_) return;
  const bool ok = gain == GainController::kHardwareAgc ? source_->set_hardware_agc() : source_->set_gain(gain);
  if (!ok && source_->device_gone()) {
    report_lost(-4, "The receiver disconnected");
    return;
  }
  // The control transfer paused sample delivery. Start the stall clock over
  // so that pause is not reported as a lost receiver.
  last_data_ms_.store(steady_ms(), std::memory_order_release);
  applied_gain_ = gain;
}

void Engine::dsp_loop() {
  while (dsp_running_) {
    run_posted();

    const size_t available = iq_ring_.size() & ~size_t{1};
    if (available == 0) {
      if (source_ended_ && !ended_emitted_) {
        ended_emitted_ = true;
        emit_source_state(TERRA_SOURCE_STATE_ENDED, 0, "end of recording");
      }
      check_stalled();
      std::unique_lock<std::mutex> lock(wake_mutex_);
      wake_.wait_for(lock, std::chrono::milliseconds(20));
      continue;
    }

    size_t n = std::min(available, chunk_.size());
    n = iq_ring_.read(chunk_.data(), n);
    size_t offset = 0;
    if (discard_bytes_ > 0) {
      offset = std::min(n, discard_bytes_);
      discard_bytes_ -= offset;
      if (offset == n) continue;
    }

    pipeline_->process(chunk_.data() + offset, n - offset);
    const auto& out = pipeline_->output();
    const size_t frames = out.size() / 2;
    if (frames > 0) {
      if (audio_enabled_) audio_.write(out.data(), frames);
      std::lock_guard<std::mutex> lock(pcm_mutex_);
      if (pcm_callback_) pcm_callback_(pcm_user_, out.data(), static_cast<int32_t>(frames));
    }
    emit_periodic();
  }
}

void Engine::emit_periodic() {
  auto& p = *pipeline_;
  const uint64_t samples = p.samples();
  const auto stream_us = static_cast<int64_t>(p.seconds() * 1e6);

  SignalReport report;
  if (p.meter().take_report(report)) {
    EventBuilder b(TERRA_EVENT_SIGNAL);
    auto& s = b.ev().u.signal;
    s.rms_dbfs = report.rms_dbfs;
    s.peak_dbfs = report.peak_dbfs;
    s.clip_ratio = report.clip_ratio;
    s.channel_dbfs = report.channel_dbfs;
    s.noise_dbfs = report.noise_dbfs;
    s.snr_db = report.snr_db;
    s.gain_tenth_db = gain_.current_gain();
    events_.emit(b);

    const int g = gain_.update(report, p.hd().synced(), p.hd().quality(), p.fm().status().cnr_db,
                               stream_us);
    if (g != GainController::kNoChange) {
      apply_gain(g);
      emit_gain();
    } else if (gain_.take_converged_event()) {
      emit_gain();
    }
  }

  if (spectrum_enabled_ && p.meter().take_spectrum(spectrum_)) {
    EventBuilder b(TERRA_EVENT_SPECTRUM);
    auto& s = b.ev().u.spectrum;
    s.center_hz = frequency_hz_;
    s.span_hz = TERRA_IQ_SAMPLE_RATE;
    b.set_floats(&s.bins_db, spectrum_.data(), spectrum_.size());
    s.bins_count = static_cast<int32_t>(spectrum_.size());
    events_.emit(b);
  }

  auto& rds = p.fm().rds().groups();
  if (rds.take_changed()) {
    const auto& d = rds.data();
    EventBuilder b(TERRA_EVENT_RDS);
    auto& r = b.ev().u.rds;
    r.pi = d.pi;
    r.pty = d.pty;
    r.tp = d.tp;
    r.ta = d.ta;
    r.ms = d.ms;
    if (!d.ps.empty()) b.set_string(&r.ps, d.ps);
    if (!d.rt.empty()) b.set_string(&r.rt, d.rt);
    events_.emit(b);
  }

  if (samples >= next_fm_status_) {
    next_fm_status_ = samples + seconds_to_samples(kStatusIntervalSeconds);
    const auto& st = p.fm().status();
    EventBuilder b(TERRA_EVENT_FM_STATUS);
    auto& f = b.ev().u.fm_status;
    f.cnr_db = st.cnr_db;
    f.pilot_level = st.pilot_level;
    f.stereo = st.stereo;
    f.stereo_blend = st.stereo_blend;
    f.squelched = st.squelched;
    f.rds_synced = rds.synced();
    f.rds_block_error_rate = rds.block_error_rate();
    events_.emit(b);
  }

  if (samples >= next_audio_status_) {
    next_audio_status_ = samples + seconds_to_samples(kStatusIntervalSeconds);
    EventBuilder b(TERRA_EVENT_AUDIO_STATUS);
    auto& a = b.ev().u.audio_status;
    a.active = p.mixer().active_source();
    a.hd_available = p.mixer().hd_available();
    a.program = p.mixer().program();
    a.mode = p.mixer().mode();
    a.buffer_ms = audio_.buffer_ms();
    a.underruns = audio_.underruns();
    audio_.take_levels(a.level_left_db, a.level_right_db);
    a.device_running = audio_.running();
    a.device_sample_rate = audio_.device_sample_rate();
    events_.emit(b);

    const uint64_t dropped = dropped_bytes_.load();
    if (dropped > last_drop_log_) {
      events_.log(TERRA_LOG_WARN, "engine", "dropped %llu KiB of IQ (DSP behind)",
                  static_cast<unsigned long long>((dropped - last_drop_log_) / 1024));
      last_drop_log_ = dropped;
    }
  }
}

// ---------------------------------------------------------------------------
// Event helpers (any thread)
// ---------------------------------------------------------------------------

void Engine::emit_source_state(terra_source_state state, int error, const std::string& message) {
  EventBuilder b(TERRA_EVENT_SOURCE_STATE);
  auto& s = b.ev().u.source_state;
  s.state = state;
  s.error_code = error;
  if (!message.empty()) b.set_string(&s.message, message);
  events_.emit(b);
}

void Engine::emit_device_info() {
  if (!source_) return;
  const auto& info = source_->info();
  EventBuilder b(TERRA_EVENT_DEVICE_INFO);
  auto& d = b.ev().u.device_info;
  b.set_string(&d.description, info.description);
  b.set_string(&d.tuner, info.tuner);
  std::vector<int32_t> gains(info.gains.begin(), info.gains.end());
  if (!gains.empty()) b.set_ints(&d.gains, gains.data(), gains.size());
  d.gain_count = static_cast<int32_t>(gains.size());
  d.supports_bias_tee = info.supports_bias_tee;
  events_.emit(b);
}

void Engine::emit_gain() {
  EventBuilder b(TERRA_EVENT_GAIN);
  auto& g = b.ev().u.gain;
  g.mode = gain_.mode();
  g.gain_tenth_db = gain_.current_gain();
  g.converged = gain_.converged();
  events_.emit(b);
}

}  // namespace terra
