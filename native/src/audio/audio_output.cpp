#include "audio/audio_output.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "dsp/math.h"
#include "miniaudio.h"

namespace terra {

namespace {
constexpr double kInputRate = 44100.0;
constexpr size_t kTargetMs = 250;
constexpr size_t kCapacityMs = 2000;
constexpr double kTrimGain = 0.002;
constexpr double kTrimLimit = 0.003;

void device_callback(ma_device* device, void* output, const void* /*input*/, ma_uint32 frames) {
  static_cast<AudioOutput*>(device->pUserData)->render(static_cast<float*>(output), frames);
}
}  // namespace

struct AudioOutput::Device {
  ma_device device;
  bool initialized = false;
};

AudioOutput::AudioOutput(EventSink& events)
    : events_(events),
      ring_(static_cast<size_t>(kInputRate) * 2 * kCapacityMs / 1000),
      target_frames_(static_cast<size_t>(kInputRate) * kTargetMs / 1000) {
  scratch_in_.resize(512 * 2);
  pending_.reserve(8192 * 2);
}

AudioOutput::~AudioOutput() { stop(); }

bool AudioOutput::start() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (running_) return true;
  if (!device_) device_ = std::make_unique<Device>();

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = 2;
  config.sampleRate = 0;  // device native rate; we resample ourselves
  config.dataCallback = device_callback;
  config.pUserData = this;
  config.performanceProfile = ma_performance_profile_conservative;
  config.aaudio.usage = ma_aaudio_usage_media;
  config.aaudio.contentType = ma_aaudio_content_type_music;
  config.opensl.streamType = ma_opensl_stream_type_media;

  if (ma_device_init(nullptr, &config, &device_->device) != MA_SUCCESS) {
    events_.log(TERRA_LOG_ERROR, "audio", "ma_device_init failed");
    return false;
  }
  device_->initialized = true;
  const int rate = static_cast<int>(device_->device.sampleRate);
  device_rate_.store(rate);
  resampler_.configure(kInputRate, static_cast<double>(rate), 2, 32, 256);
  pending_.clear();
  pending_pos_ = 0;
  prebuffering_ = true;
  drift_error_ = 0.0;
  gain_ = 0.0f;

  if (ma_device_start(&device_->device) != MA_SUCCESS) {
    events_.log(TERRA_LOG_ERROR, "audio", "ma_device_start failed");
    ma_device_uninit(&device_->device);
    device_->initialized = false;
    return false;
  }
  running_ = true;
  events_.log(TERRA_LOG_INFO, "audio", "output started: %s @ %d Hz",
              ma_get_backend_name(device_->device.pContext->backend), rate);
  return true;
}

void AudioOutput::stop() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  if (!device_ || !device_->initialized) return;
  ma_device_uninit(&device_->device);
  device_->initialized = false;
  running_ = false;
}

void AudioOutput::write(const float* frames, size_t frame_count) {
  if (!running_) return;
  ring_.write(frames, frame_count * 2);
}

float AudioOutput::buffer_ms() const {
  return static_cast<float>(ring_.size() / 2) * 1000.0f / static_cast<float>(kInputRate);
}

void AudioOutput::take_levels(float& left_db, float& right_db) {
  const float l = peak_l_.exchange(0.0f);
  const float r = peak_r_.exchange(0.0f);
  left_db = db_from_power(static_cast<double>(l) * l);
  right_db = db_from_power(static_cast<double>(r) * r);
}

void AudioOutput::render(float* out, unsigned int frames) {
  if (flush_requested_.exchange(false)) {
    ring_.clear();
    pending_.clear();
    pending_pos_ = 0;
    resampler_.reset();
    prebuffering_ = true;
  }

  const size_t buffered = ring_.size() / 2;
  if (prebuffering_) {
    if (buffered < target_frames_) {
      std::memset(out, 0, sizeof(float) * frames * 2);
      return;
    }
    prebuffering_ = false;
  }

  // Drift trim: consume slightly faster when the buffer runs deep.
  const double error = (static_cast<double>(buffered) - static_cast<double>(target_frames_)) /
                       static_cast<double>(target_frames_);
  drift_error_ += 0.01 * (error - drift_error_);
  resampler_.set_trim(1.0 + clamp(kTrimGain * drift_error_, -kTrimLimit, kTrimLimit));

  size_t produced = 0;
  float peak_l = 0.0f, peak_r = 0.0f;
  const float target_gain = volume_.load();
  while (produced < frames) {
    if (pending_pos_ >= pending_.size() / 2) {
      pending_.clear();
      pending_pos_ = 0;
      const size_t got = ring_.read(scratch_in_.data(), scratch_in_.size()) / 2;
      if (got == 0) {
        underruns_.fetch_add(1);
        prebuffering_ = true;
        std::memset(out + produced * 2, 0, sizeof(float) * (frames - produced) * 2);
        break;
      }
      resampler_.process(scratch_in_.data(), got, pending_);
      continue;
    }
    gain_ += 0.001f * (target_gain - gain_);
    const float l = pending_[pending_pos_ * 2] * gain_;
    const float r = pending_[pending_pos_ * 2 + 1] * gain_;
    ++pending_pos_;
    out[produced * 2] = l;
    out[produced * 2 + 1] = r;
    peak_l = std::max(peak_l, std::abs(l));
    peak_r = std::max(peak_r, std::abs(r));
    ++produced;
  }

  if (peak_l > peak_l_.load()) peak_l_.store(peak_l);
  if (peak_r > peak_r_.load()) peak_r_.store(peak_r);
}

}  // namespace terra
