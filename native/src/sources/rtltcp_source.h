#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

#include "events.h"
#include "sources/iq_source.h"

namespace terra {

// rtl_tcp client (rtl_tcp, rtl_tcp_andro, SDR++ server in rtl_tcp mode).
class RtlTcpSource : public IqSource {
 public:
  RtlTcpSource(EventSink& events, std::string host, int port);
  ~RtlTcpSource() override;

  bool open(std::string& error) override;
  bool start(DataHandler on_data, StateHandler on_state) override;
  void stop() override;

  bool set_frequency(uint32_t hz) override;
  bool set_gain(int tenth_db) override;
  bool set_hardware_agc() override;
  bool set_ppm(int ppm) override;
  bool set_bias_tee(bool enabled) override;
  // Wi-Fi hiccups are longer than a USB buffer gap.
  int stall_timeout_ms() const override { return 6000; }

 private:
  bool send_command(uint8_t cmd, uint32_t param);
  void read_loop();
  void close_socket();

  EventSink& events_;
  std::string host_;
  int port_;
  intptr_t socket_ = -1;
  std::mutex send_mutex_;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  DataHandler on_data_;
  StateHandler on_state_;
};

}  // namespace terra
