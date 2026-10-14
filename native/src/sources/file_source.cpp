#include "sources/file_source.h"

#include <chrono>
#include <vector>

namespace terra {

FileSource::FileSource(EventSink& events, std::string path, bool realtime, bool loop)
    : events_(events), path_(std::move(path)), realtime_(realtime), loop_(loop) {}

FileSource::~FileSource() {
  stop();
  if (file_) std::fclose(file_);
}

bool FileSource::open(std::string& error) {
  file_ = std::fopen(path_.c_str(), "rb");
  if (!file_) {
    error = "cannot open " + path_;
    return false;
  }
  const auto slash = path_.find_last_of("/\\");
  info_.description = "Recording: " + (slash == std::string::npos ? path_ : path_.substr(slash + 1));
  info_.tuner = "file";
  return true;
}

bool FileSource::start(DataHandler on_data, StateHandler on_state) {
  if (!file_ || thread_.joinable()) return false;
  on_data_ = std::move(on_data);
  on_state_ = std::move(on_state);
  stopping_ = false;
  thread_ = std::thread([this] { read_loop(); });
  return true;
}

void FileSource::read_loop() {
  using clock = std::chrono::steady_clock;
  constexpr size_t kChunk = 32768;
  constexpr double kBytesPerSecond = 2.0 * TERRA_IQ_SAMPLE_RATE;
  std::vector<uint8_t> buf(kChunk);
  const auto start = clock::now();
  uint64_t sent = 0;

  while (!stopping_) {
    size_t n = std::fread(buf.data(), 1, kChunk, file_);
    n &= ~size_t{1};
    if (n == 0) {
      if (loop_) {
        std::rewind(file_);
        continue;
      }
      events_.log(TERRA_LOG_INFO, "file", "end of %s after %.1f s", path_.c_str(),
                  static_cast<double>(sent) / kBytesPerSecond);
      if (on_state_) on_state_(TERRA_SOURCE_STATE_ENDED, 0, "end of recording");
      return;
    }
    on_data_(buf.data(), n);
    sent += n;
    if (realtime_) {
      const auto due = start + std::chrono::microseconds(static_cast<int64_t>(sent * 1e6 / kBytesPerSecond));
      std::this_thread::sleep_until(due);
    }
  }
}

void FileSource::stop() {
  if (!thread_.joinable()) return;
  stopping_ = true;
  thread_.join();
}

}  // namespace terra
