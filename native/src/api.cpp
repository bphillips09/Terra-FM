#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include "engine.h"
#include "sources/rtlsdr_source.h"
#include "terra_core.h"

#ifndef TERRA_VERSION
#define TERRA_VERSION "0.1.0"
#endif

namespace {

// The parts of Dart_CObject (dart_native_api.h) used here: a null or an
// int64, with the union padded to its full size.
constexpr int32_t kDartNull = 0;   // Dart_CObject_kNull
constexpr int32_t kDartInt64 = 3;  // Dart_CObject_kInt64
struct DartCObject {
  int32_t type;
  union {
    int64_t as_int64;
    unsigned char pad[40];
  } value;
};

}  // namespace

struct terra_engine {
  // Declared before engine: the DSP thread can queue events as soon as the
  // engine starts, and the queue outlives the engine so shutdown can drain it.
  struct EventQueue {
    std::mutex mu;
    std::deque<terra_event*> items;
    static constexpr size_t kCap = 512;

    void push(terra_event* event) {
      std::lock_guard<std::mutex> lock(mu);
      if (items.size() >= kCap) {
        terra_event_free(event);
        return;
      }
      items.push_back(event);
    }

    terra_event* pop() {
      std::lock_guard<std::mutex> lock(mu);
      if (items.empty()) return nullptr;
      auto* event = items.front();
      items.pop_front();
      return event;
    }

    ~EventQueue() {
      for (auto* event : items) terra_event_free(event);
    }
  };

  terra_engine(terra_event_callback cb, void* user) : engine(cb, user) {}
  terra_engine(terra_post_message post_fn, int64_t port_id)
      : post(post_fn), port(port_id), engine(&terra_engine::forward, this) {}

  // Queue only. Calling Dart_PostCObject here races a hot restart: the VM
  // unmaps the old isolate while this thread is still inside the call.
  static void forward(void* user, terra_event* event) {
    auto* self = static_cast<terra_engine*>(user);
    if (self->orphaned.load(std::memory_order_acquire)) {
      terra_event_free(event);
      return;
    }
    self->queue.push(event);
  }

  // A null message to a live port is delivered (and ignored); a closed port
  // refuses it.
  bool port_open() {
    if (orphaned) return false;
    DartCObject message{};
    message.type = kDartNull;
    if (post(port, &message)) return true;
    orphaned = true;
    return false;
  }

  terra_post_message post = nullptr;
  int64_t port = 0;
  std::atomic<bool> orphaned{false};
  EventQueue queue;
  terra::Engine engine;
};

namespace {

// Port engines, so a new isolate can find the ones its predecessor left
// running. Function-local to avoid static initialization order issues.
std::mutex& registry_mutex() {
  static std::mutex m;
  return m;
}

std::vector<terra_engine*>& registry() {
  static std::vector<terra_engine*> engines;
  return engines;
}

void unregister(terra_engine* engine) {
  std::lock_guard<std::mutex> lock(registry_mutex());
  auto& list = registry();
  list.erase(std::remove(list.begin(), list.end(), engine), list.end());
}

}  // namespace

extern "C" {

TERRA_API int32_t terra_api_version(void) { return TERRA_API_VERSION; }

TERRA_API const char* terra_version_string(void) { return "terra_core " TERRA_VERSION; }

TERRA_API terra_engine* terra_engine_create(terra_event_callback callback, void* user_data) {
  return new (std::nothrow) terra_engine(callback, user_data);
}

TERRA_API terra_engine* terra_engine_create_for_port(terra_post_message post, int64_t port) {
  if (!post) return nullptr;
  auto* engine = new (std::nothrow) terra_engine(post, port);
  if (!engine) return nullptr;
  std::lock_guard<std::mutex> lock(registry_mutex());
  registry().push_back(engine);
  return engine;
}

TERRA_API void terra_engine_destroy(terra_engine* engine) {
  if (!engine) return;
  unregister(engine);
  delete engine;
}

TERRA_API int64_t terra_engine_poll_event(terra_engine* engine) {
  if (!engine) return 0;
  terra_event* event = engine->queue.pop();
  return event ? static_cast<int64_t>(reinterpret_cast<intptr_t>(event)) : 0;
}

TERRA_API int32_t terra_engine_destroy_orphans(void) {
  std::vector<terra_engine*> orphans;
  {
    std::lock_guard<std::mutex> lock(registry_mutex());
    auto& list = registry();
    for (auto it = list.begin(); it != list.end();) {
      if ((*it)->port_open()) {
        ++it;
      } else {
        orphans.push_back(*it);
        it = list.erase(it);
      }
    }
  }
  for (auto* engine : orphans) delete engine;
  return static_cast<int32_t>(orphans.size());
}

TERRA_API int32_t terra_engine_open(terra_engine* engine, const terra_source_config* config) {
  if (!engine || !config) return -1;
  return engine->engine.open(*config);
}

TERRA_API void terra_engine_close(terra_engine* engine) {
  if (engine) engine->engine.close();
}

TERRA_API int32_t terra_engine_tune(terra_engine* engine, uint32_t frequency_hz,
                                    int32_t gain_hint_tenth_db) {
  if (!engine) return -1;
  return engine->engine.tune(frequency_hz, gain_hint_tenth_db);
}

TERRA_API void terra_engine_set_program(terra_engine* engine, int32_t program) {
  if (engine) engine->engine.set_program(program);
}

TERRA_API void terra_engine_set_audio_mode(terra_engine* engine, int32_t mode) {
  if (engine) engine->engine.set_audio_mode(mode);
}

TERRA_API void terra_engine_set_gain(terra_engine* engine, int32_t mode, int32_t gain_tenth_db) {
  if (engine) engine->engine.set_gain(mode, gain_tenth_db);
}

TERRA_API void terra_engine_set_ppm(terra_engine* engine, int32_t ppm) {
  if (engine) engine->engine.set_ppm(ppm);
}

TERRA_API void terra_engine_set_bias_tee(terra_engine* engine, int32_t enabled) {
  if (engine) engine->engine.set_bias_tee(enabled != 0);
}

TERRA_API void terra_engine_set_deemphasis_us(terra_engine* engine, int32_t microseconds) {
  if (engine) engine->engine.set_deemphasis_us(microseconds);
}

TERRA_API void terra_engine_set_blend_alignment_ms(terra_engine* engine, int32_t milliseconds) {
  if (engine) engine->engine.set_blend_alignment_ms(milliseconds);
}

TERRA_API void terra_engine_set_squelch_db(terra_engine* engine, int32_t threshold_db) {
  if (engine) engine->engine.set_squelch_db(threshold_db);
}

TERRA_API void terra_engine_set_volume(terra_engine* engine, float volume) {
  if (engine) engine->engine.set_volume(volume);
}

TERRA_API void terra_engine_set_hd_level(terra_engine* engine, float level) {
  if (engine) engine->engine.set_hd_level(level);
}

TERRA_API void terra_engine_set_audio_enabled(terra_engine* engine, int32_t enabled) {
  if (engine) engine->engine.set_audio_enabled(enabled != 0);
}

TERRA_API void terra_engine_set_spectrum_enabled(terra_engine* engine, int32_t enabled) {
  if (engine) engine->engine.set_spectrum_enabled(enabled != 0);
}

TERRA_API void terra_engine_set_pcm_callback(terra_engine* engine, terra_pcm_callback callback,
                                             void* user_data) {
  if (engine) engine->engine.set_pcm_callback(callback, user_data);
}

TERRA_API void terra_event_free(terra_event* event) { std::free(event); }

TERRA_API int32_t terra_rtlsdr_device_count(void) { return terra::RtlSdrSource::device_count(); }

TERRA_API int32_t terra_rtlsdr_device_name(int32_t index, char* buffer, int32_t buffer_size) {
  if (!buffer || buffer_size <= 0) return -1;
  std::string name;
  if (!terra::RtlSdrSource::device_name(index, name)) return -1;
  const size_t n = std::min(name.size(), static_cast<size_t>(buffer_size - 1));
  std::memcpy(buffer, name.data(), n);
  buffer[n] = '\0';
  return 0;
}

}  // extern "C"
