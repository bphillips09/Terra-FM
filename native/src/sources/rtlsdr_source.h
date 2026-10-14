#pragma once

#include <atomic>
#include <thread>

#include "events.h"
#include "sources/iq_source.h"

struct rtlsdr_dev;

namespace terra {

// librtlsdr device opened by index (desktop) or by an already-open USB file
// descriptor (Android: UsbDeviceConnection.getFileDescriptor()).
class RtlSdrSource : public IqSource {
 public:
  static RtlSdrSource* from_fd(EventSink& events, int fd);
  static RtlSdrSource* from_index(EventSink& events, int index);
  ~RtlSdrSource() override;

  bool open(std::string& error) override;
  bool start(DataHandler on_data, StateHandler on_state) override;
  void stop() override;
  bool restart() override;

  bool set_frequency(uint32_t hz) override;
  bool set_gain(int tenth_db) override;
  bool set_hardware_agc() override;
  bool set_ppm(int ppm) override;
  bool set_bias_tee(bool enabled) override;
  bool device_gone() const override { return gone_; }

  static int device_count();
  static bool device_name(int index, std::string& name);

 private:
  RtlSdrSource(EventSink& events, int fd, int index);
  static void read_callback(unsigned char* buf, uint32_t len, void* ctx);
  void read_loop();
  bool check(int result);

  EventSink& events_;
  int fd_;
  int index_;
  rtlsdr_dev* dev_ = nullptr;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> restarting_{false};
  std::atomic<bool> gone_{false};
  DataHandler on_data_;
  StateHandler on_state_;
  int ppm_ = 0;
};

}  // namespace terra
