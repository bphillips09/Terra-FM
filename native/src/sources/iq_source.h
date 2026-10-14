#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "terra_core.h"

namespace terra {

struct SourceInfo {
  std::string description;
  std::string tuner;
  std::vector<int> gains;  // tenths of dB, ascending
  bool supports_bias_tee = false;
};

// Delivers unsigned 8-bit interleaved IQ at TERRA_IQ_SAMPLE_RATE from its own
// thread. Control methods are called from one thread at a time (the engine
// serializes them).
class IqSource {
 public:
  using DataHandler = std::function<void(const uint8_t* data, size_t bytes)>;
  using StateHandler = std::function<void(terra_source_state state, int error, const std::string& message)>;

  virtual ~IqSource() = default;

  virtual bool open(std::string& error) = 0;
  virtual bool start(DataHandler on_data, StateHandler on_state) = 0;
  virtual void stop() = 0;

  // The device is still open, but the sample pipe has gone quiet. Stop and
  // start streaming again. False when this source cannot do that.
  virtual bool restart() { return false; }

  virtual bool set_frequency(uint32_t hz) = 0;
  virtual bool set_gain(int tenth_db) = 0;  // manual tuner gain
  virtual bool set_hardware_agc() = 0;
  virtual bool set_ppm(int ppm) = 0;
  virtual bool set_bias_tee(bool enabled) = 0;

  // Live devices tune; recordings do not.
  virtual bool tunable() const { return true; }
  // A control call found the hardware missing (unplugged, or reset by the
  // host). Nothing will work until the source is reopened.
  virtual bool device_gone() const { return false; }
  // How long a live source may go without delivering samples before it is
  // considered lost.
  virtual int stall_timeout_ms() const { return 2500; }
  // Lossless sources block when the engine is behind instead of dropping.
  virtual bool lossless() const { return false; }

  const SourceInfo& info() const { return info_; }

 protected:
  SourceInfo info_;
};

}  // namespace terra
