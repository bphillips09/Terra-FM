#pragma once

#include <atomic>
#include <cstdio>
#include <string>
#include <thread>

#include "events.h"
#include "sources/iq_source.h"

namespace terra {

// Raw cu8 recording at TERRA_IQ_SAMPLE_RATE (e.g. `rtl_sdr -s 1488375`).
class FileSource : public IqSource {
 public:
  FileSource(EventSink& events, std::string path, bool realtime, bool loop);
  ~FileSource() override;

  bool open(std::string& error) override;
  bool start(DataHandler on_data, StateHandler on_state) override;
  void stop() override;

  bool set_frequency(uint32_t) override { return true; }
  bool set_gain(int) override { return true; }
  bool set_hardware_agc() override { return true; }
  bool set_ppm(int) override { return true; }
  bool set_bias_tee(bool) override { return false; }

  bool tunable() const override { return false; }
  bool lossless() const override { return !realtime_; }

 private:
  void read_loop();

  EventSink& events_;
  std::string path_;
  bool realtime_;
  bool loop_;
  std::FILE* file_ = nullptr;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  DataHandler on_data_;
  StateHandler on_state_;
};

}  // namespace terra
