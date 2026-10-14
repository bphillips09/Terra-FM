#pragma once

#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "terra_core.h"

namespace terra {

inline int64_t now_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Builds a terra_event whose strings and arrays live in the same heap block,
// so the receiver frees everything with a single terra_event_free().
class EventBuilder {
 public:
  explicit EventBuilder(terra_event_type type);

  terra_event& ev() { return ev_; }

  void set_string(const char** field, const char* value);
  void set_string(const char** field, const std::string& value);
  void set_bytes(const uint8_t** field, const void* data, size_t size);
  void set_floats(const float** field, const float* data, size_t count);
  void set_ints(const int32_t** field, const int32_t* data, size_t count);

  // Caller owns the result (free with terra_event_free).
  terra_event* build() const;

 private:
  struct Piece {
    size_t field_offset;
    std::vector<uint8_t> bytes;
  };
  void add_piece(const void* field, const void* data, size_t size, bool nul);

  terra_event ev_;
  std::vector<Piece> pieces_;
};

// Delivers events to the host. Thread-safe.
class EventSink {
 public:
  using Handler = std::function<void(terra_event*)>;

  EventSink() = default;
  explicit EventSink(Handler handler) : handler_(std::move(handler)) {}

  void set_handler(Handler handler);
  void emit(const EventBuilder& builder);

  void log(terra_log_level level, const char* tag, const char* fmt, ...)
#if defined(__GNUC__)
      __attribute__((format(printf, 4, 5)))
#endif
      ;

 private:
  std::mutex mutex_;
  Handler handler_;
};

}  // namespace terra
