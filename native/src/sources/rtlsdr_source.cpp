#include "sources/rtlsdr_source.h"

#include <rtl-sdr.h>

#include <algorithm>
#include <cstring>

namespace terra {

namespace {
constexpr uint32_t kBufferCount = 12;
constexpr uint32_t kBufferBytes = 32768;  // ~11 ms each; keeps retune latency low

// librtlsdr passes libusb errors through unchanged.
constexpr int kLibusbNoDevice = -4;  // LIBUSB_ERROR_NO_DEVICE

const char* tuner_name(rtlsdr_tuner t) {
  switch (t) {
    case RTLSDR_TUNER_E4000: return "Elonics E4000";
    case RTLSDR_TUNER_FC0012: return "Fitipower FC0012";
    case RTLSDR_TUNER_FC0013: return "Fitipower FC0013";
    case RTLSDR_TUNER_FC2580: return "FCI FC2580";
    case RTLSDR_TUNER_R820T: return "Rafael Micro R820T/R820T2";
    case RTLSDR_TUNER_R828D: return "Rafael Micro R828D";
    default: return "Unknown";
  }
}
}  // namespace

RtlSdrSource::RtlSdrSource(EventSink& events, int fd, int index)
    : events_(events), fd_(fd), index_(index) {}

RtlSdrSource* RtlSdrSource::from_fd(EventSink& events, int fd) {
  return new RtlSdrSource(events, fd, -1);
}

RtlSdrSource* RtlSdrSource::from_index(EventSink& events, int index) {
  return new RtlSdrSource(events, -1, index);
}

RtlSdrSource::~RtlSdrSource() {
  stop();
  if (dev_) {
    rtlsdr_close(dev_);
    dev_ = nullptr;
  }
}

bool RtlSdrSource::open(std::string& error) {
  int r;
  if (fd_ >= 0) {
    r = rtlsdr_open_sys_dev(&dev_, static_cast<intptr_t>(fd_));
  } else {
    r = rtlsdr_open(&dev_, static_cast<uint32_t>(std::max(0, index_)));
  }
  if (r < 0 || !dev_) {
    dev_ = nullptr;
    error = "rtlsdr open failed (" + std::to_string(r) + ")";
    return false;
  }

  if (rtlsdr_set_sample_rate(dev_, TERRA_IQ_SAMPLE_RATE) < 0) {
    error = "rtlsdr_set_sample_rate failed";
    return false;
  }
  rtlsdr_set_agc_mode(dev_, 0);
  rtlsdr_set_tuner_bandwidth(dev_, 0);
  rtlsdr_set_tuner_gain_mode(dev_, 1);

  const rtlsdr_tuner tuner = rtlsdr_get_tuner_type(dev_);
  info_.tuner = tuner_name(tuner);
  info_.supports_bias_tee = tuner == RTLSDR_TUNER_R820T || tuner == RTLSDR_TUNER_R828D;

  const int count = rtlsdr_get_tuner_gains(dev_, nullptr);
  if (count > 0) {
    std::vector<int> gains(static_cast<size_t>(count));
    rtlsdr_get_tuner_gains(dev_, gains.data());
    std::sort(gains.begin(), gains.end());
    info_.gains = std::move(gains);
  }

  char manufact[256] = {0}, product[256] = {0}, serial[256] = {0};
  rtlsdr_get_usb_strings(dev_, manufact, product, serial);
  std::string desc = std::string(manufact) + " " + product;
  if (desc == " ") desc = "Tuner";
  if (serial[0]) desc += std::string(" (SN ") + serial + ")";
  info_.description = desc;

  rtlsdr_reset_buffer(dev_);
  events_.log(TERRA_LOG_INFO, "rtlsdr", "opened %s, tuner %s, %d gains", info_.description.c_str(),
              info_.tuner.c_str(), count);
  return true;
}

bool RtlSdrSource::start(DataHandler on_data, StateHandler on_state) {
  if (!dev_ || thread_.joinable()) return false;
  on_data_ = std::move(on_data);
  on_state_ = std::move(on_state);
  stopping_ = false;
  thread_ = std::thread([this] { read_loop(); });
  return true;
}

void RtlSdrSource::read_callback(unsigned char* buf, uint32_t len, void* ctx) {
  auto* self = static_cast<RtlSdrSource*>(ctx);
  if (self->stopping_) return;
  self->on_data_(buf, len & ~1u);
}

void RtlSdrSource::read_loop() {
  const int r = rtlsdr_read_async(dev_, &RtlSdrSource::read_callback, this, kBufferCount, kBufferBytes);
  // restart() cancels the read on purpose; the caller starts it again.
  if (restarting_.load(std::memory_order_acquire) && !stopping_) return;
  if (!stopping_) {
    events_.log(TERRA_LOG_WARN, "rtlsdr", "stream ended (%d)", r);
    if (on_state_) {
      on_state_(TERRA_SOURCE_STATE_LOST, r,
                gone_ ? "The tuner disconnected" : "The tuner stopped streaming");
    }
  }
}

void RtlSdrSource::stop() {
  if (!thread_.joinable()) return;
  stopping_ = true;
  if (dev_) rtlsdr_cancel_async(dev_);
  thread_.join();
}

bool RtlSdrSource::restart() {
  if (!dev_ || stopping_ || gone_ || !thread_.joinable()) return false;
  // Set before cancel so the read thread does not report the tuner lost
  // when read_async returns.
  restarting_.store(true, std::memory_order_release);
  rtlsdr_cancel_async(dev_);
  thread_.join();
  const bool ok = dev_ && !stopping_ && !gone_;
  if (ok) rtlsdr_reset_buffer(dev_);
  restarting_.store(false, std::memory_order_release);
  if (!ok) return false;
  thread_ = std::thread([this] { read_loop(); });
  return true;
}

// On macOS the bulk transfers of a vanished tuner can fail without ending
// rtlsdr_read_async, so a control call is often the first to notice. Cancel
// the read so its thread exits and reports the loss.
bool RtlSdrSource::check(int result) {
  if (result == kLibusbNoDevice && !gone_.exchange(true)) {
    events_.log(TERRA_LOG_ERROR, "rtlsdr", "device is gone (libusb %d)", result);
    if (dev_) rtlsdr_cancel_async(dev_);
  }
  return result >= 0;
}

bool RtlSdrSource::set_frequency(uint32_t hz) {
  return dev_ && check(rtlsdr_set_center_freq(dev_, hz));
}

bool RtlSdrSource::set_gain(int tenth_db) {
  if (!dev_) return false;
  if (!check(rtlsdr_set_tuner_gain_mode(dev_, 1))) return false;
  return check(rtlsdr_set_tuner_gain(dev_, tenth_db));
}

bool RtlSdrSource::set_hardware_agc() {
  return dev_ && check(rtlsdr_set_tuner_gain_mode(dev_, 0));
}

bool RtlSdrSource::set_ppm(int ppm) {
  if (!dev_) return false;
  if (ppm == ppm_) return true;
  // librtlsdr returns -2 when the value is unchanged.
  const int r = rtlsdr_set_freq_correction(dev_, ppm);
  if (r >= 0 || r == -2) {
    ppm_ = ppm;
    return true;
  }
  check(r);
  return false;
}

bool RtlSdrSource::set_bias_tee(bool enabled) {
  return dev_ && check(rtlsdr_set_bias_tee(dev_, enabled ? 1 : 0));
}

int RtlSdrSource::device_count() {
#if defined(__ANDROID__)
  return 0;
#else
  return static_cast<int>(rtlsdr_get_device_count());
#endif
}

bool RtlSdrSource::device_name(int index, std::string& name) {
#if defined(__ANDROID__)
  (void)index;
  (void)name;
  return false;
#else
  char manufact[256] = {0}, product[256] = {0}, serial[256] = {0};
  if (rtlsdr_get_device_usb_strings(static_cast<uint32_t>(index), manufact, product, serial) < 0) {
    const char* fallback = rtlsdr_get_device_name(static_cast<uint32_t>(index));
    if (!fallback || !*fallback) return false;
    name = fallback;
    return true;
  }
  name = std::string(manufact) + " " + product;
  if (serial[0]) name += std::string(" (SN ") + serial + ")";
  return true;
#endif
}

}  // namespace terra
