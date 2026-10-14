#include "events.h"

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#if defined(__ANDROID__)
#include <android/log.h>
#endif

namespace terra {

namespace {
constexpr size_t kAlign = alignof(std::max_align_t);
size_t align_up(size_t v) { return (v + kAlign - 1) & ~(kAlign - 1); }
}  // namespace

EventBuilder::EventBuilder(terra_event_type type) {
  std::memset(&ev_, 0, sizeof(ev_));
  ev_.type = type;
  ev_.timestamp_us = now_us();
}

void EventBuilder::add_piece(const void* field, const void* data, size_t size, bool nul) {
  Piece piece;
  piece.field_offset = static_cast<size_t>(reinterpret_cast<const uint8_t*>(field) -
                                           reinterpret_cast<const uint8_t*>(&ev_));
  piece.bytes.resize(size + (nul ? 1 : 0));
  if (size > 0) std::memcpy(piece.bytes.data(), data, size);
  if (nul) piece.bytes[size] = 0;
  // Replace an earlier value for the same field.
  for (auto& existing : pieces_) {
    if (existing.field_offset == piece.field_offset) {
      existing = std::move(piece);
      return;
    }
  }
  pieces_.push_back(std::move(piece));
}

void EventBuilder::set_string(const char** field, const char* value) {
  if (!value) {
    *field = nullptr;
    return;
  }
  add_piece(field, value, std::strlen(value), true);
}

void EventBuilder::set_string(const char** field, const std::string& value) {
  add_piece(field, value.data(), value.size(), true);
}

void EventBuilder::set_bytes(const uint8_t** field, const void* data, size_t size) {
  if (!data) {
    *field = nullptr;
    return;
  }
  add_piece(field, data, size, false);
}

void EventBuilder::set_floats(const float** field, const float* data, size_t count) {
  add_piece(field, data, count * sizeof(float), false);
}

void EventBuilder::set_ints(const int32_t** field, const int32_t* data, size_t count) {
  add_piece(field, data, count * sizeof(int32_t), false);
}

terra_event* EventBuilder::build() const {
  size_t total = align_up(sizeof(terra_event));
  for (const auto& piece : pieces_) total += align_up(piece.bytes.size());

  auto* block = static_cast<uint8_t*>(std::malloc(total));
  if (!block) return nullptr;
  std::memcpy(block, &ev_, sizeof(terra_event));

  size_t pos = align_up(sizeof(terra_event));
  for (const auto& piece : pieces_) {
    uint8_t* dst = block + pos;
    if (!piece.bytes.empty()) std::memcpy(dst, piece.bytes.data(), piece.bytes.size());
    const void* ptr = dst;
    std::memcpy(block + piece.field_offset, &ptr, sizeof(ptr));
    pos += align_up(piece.bytes.size());
  }
  return reinterpret_cast<terra_event*>(block);
}

void EventSink::set_handler(Handler handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  handler_ = std::move(handler);
}

void EventSink::emit(const EventBuilder& builder) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!handler_) return;
  terra_event* event = builder.build();
  if (event) handler_(event);
}

void EventSink::log(terra_log_level level, const char* tag, const char* fmt, ...) {
  char buffer[1024];
  va_list args;
  va_start(args, fmt);
  std::vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);

#if defined(__ANDROID__)
  static const int kPriorities[] = {ANDROID_LOG_DEBUG, ANDROID_LOG_INFO, ANDROID_LOG_WARN,
                                    ANDROID_LOG_ERROR};
  __android_log_print(kPriorities[level], "terra_core", "[%s] %s", tag, buffer);
#else
  if (std::getenv("TERRA_LOG_STDERR")) std::fprintf(stderr, "[terra:%s] %s\n", tag, buffer);
#endif

  EventBuilder b(TERRA_EVENT_LOG);
  b.ev().u.log.level = level;
  b.set_string(&b.ev().u.log.tag, tag);
  b.set_string(&b.ev().u.log.message, buffer);
  emit(b);
}

}  // namespace terra
