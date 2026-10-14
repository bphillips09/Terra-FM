#include "hd/hd_decoder.h"

#include <cstring>
#include <ctime>

extern "C" {
#include <nrsc5.h>
}

namespace terra {

namespace {

constexpr unsigned int kMaxTextLotBytes = 16 * 1024;

bool looks_like_image(const uint8_t* data, size_t size) {
  if (!data || size < 8) return false;
  if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;              // JPEG
  if (std::memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0) return true;                     // PNG
  if (std::memcmp(data, "GIF87a", 6) == 0 || std::memcmp(data, "GIF89a", 6) == 0) return true;
  return false;
}

int64_t to_unix(const struct tm* t) {
  if (!t) return 0;
  struct tm copy = *t;
#if defined(_WIN32)
  return static_cast<int64_t>(_mkgmtime(&copy));
#else
  return static_cast<int64_t>(timegm(&copy));
#endif
}

bool all_zero(const int16_t* data, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    if (data[i] != 0) return false;
  }
  return true;
}

// Stations pad text fields with spaces; whitespace-only becomes absent.
void set_text(EventBuilder& b, const char** field, const char* value) {
  if (!value) return;
  std::string s(value);
  const auto first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return;
  const auto last = s.find_last_not_of(" \t\r\n");
  b.set_string(field, s.substr(first, last - first + 1));
}

}  // namespace

HdDecoder::HdDecoder(EventSink& events) : events_(events) {
  if (nrsc5_open_pipe(&radio_) != 0) {
    radio_ = nullptr;
    events_.log(TERRA_LOG_ERROR, "hd", "nrsc5_open_pipe failed");
    return;
  }
  nrsc5_set_mode(radio_, NRSC5_MODE_FM);
  nrsc5_set_callback(radio_, &HdDecoder::callback, this);
  health_.fill(-1.0f);
}

HdDecoder::~HdDecoder() {
  if (radio_) nrsc5_close(radio_);
}

void HdDecoder::reset(uint32_t frequency_hz) {
  if (!radio_) return;
  // nrsc5_set_frequency resets input and output state in pipe mode, but is a
  // no-op for an unchanged frequency; bounce through 0 to force the reset.
  nrsc5_set_frequency(radio_, 0.0f);
  nrsc5_set_frequency(radio_, static_cast<float>(frequency_hz));
  frequency_hz_ = frequency_hz;
  synced_ = false;
  quality_ = HdQuality{};
  health_.fill(-1.0f);
  last_audio_us_.fill(0);
}

void HdDecoder::process_cu8(const uint8_t* iq, size_t bytes) {
  if (radio_ && bytes > 0) nrsc5_pipe_samples_cu8(radio_, iq, static_cast<unsigned int>(bytes));
}

float HdDecoder::packet_health(int program) const { return health_[clamp_program(program)]; }

void HdDecoder::callback(const nrsc5_event_t* evt, void* opaque) {
  static_cast<HdDecoder*>(opaque)->handle(evt);
}

void HdDecoder::handle(const nrsc5_event_t* evt) {
  switch (evt->event) {
    case NRSC5_EVENT_SYNC: {
      synced_ = true;
      EventBuilder b(TERRA_EVENT_HD_SYNC);
      b.ev().u.hd_sync.synced = 1;
      b.ev().u.hd_sync.freq_offset_hz = evt->sync.freq_offset;
      b.ev().u.hd_sync.psmi = evt->sync.psmi;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_LOST_SYNC: {
      synced_ = false;
      EventBuilder b(TERRA_EVENT_HD_SYNC);
      b.ev().u.hd_sync.synced = 0;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_MER:
    case NRSC5_EVENT_BER: {
      if (!synced_) break;  // meaningless before acquisition
      if (evt->event == NRSC5_EVENT_MER) {
        quality_.mer_lower = evt->mer.lower;
        quality_.mer_upper = evt->mer.upper;
      } else {
        quality_.ber = evt->ber.cber;
      }
      quality_.valid = true;
      quality_.updated_us = now_us();
      EventBuilder b(TERRA_EVENT_HD_QUALITY);
      b.ev().u.hd_quality.mer_lower_db = quality_.mer_lower;
      b.ev().u.hd_quality.mer_upper_db = quality_.mer_upper;
      b.ev().u.hd_quality.ber = quality_.ber;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_HDC: {
      const int p = clamp_program(static_cast<int>(evt->hdc.program));
      const float good = (evt->hdc.flags & NRSC5_PKT_FLAGS_CRC_ERROR) ? 0.0f : 1.0f;
      health_[p] = health_[p] < 0 ? good : health_[p] * 0.9f + good * 0.1f;
      break;
    }
    case NRSC5_EVENT_AUDIO: {
      const int p = clamp_program(static_cast<int>(evt->audio.program));
      const size_t frames = evt->audio.count / 2;
      const bool valid = !all_zero(evt->audio.data, evt->audio.count);
      if (valid) last_audio_us_[p] = now_us();
      if (audio_handler_) audio_handler_(p, evt->audio.data, frames, valid);
      break;
    }
    case NRSC5_EVENT_ID3: {
      EventBuilder b(TERRA_EVENT_HD_ID3);
      auto& e = b.ev().u.hd_id3;
      e.program = static_cast<int32_t>(evt->id3.program);
      set_text(b, &e.title, evt->id3.title);
      set_text(b, &e.artist, evt->id3.artist);
      set_text(b, &e.album, evt->id3.album);
      set_text(b, &e.genre, evt->id3.genre);
      if (evt->id3.comments) set_text(b, &e.comment, evt->id3.comments->full_text);
      b.set_string(&e.ufid_owner, evt->id3.ufid.owner);
      b.set_string(&e.ufid_id, evt->id3.ufid.id);
      e.xhdr_mime = evt->id3.xhdr.mime;
      e.xhdr_param = evt->id3.xhdr.param;
      e.xhdr_lot = evt->id3.xhdr.lot;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_LOT: {
      EventBuilder b(TERRA_EVENT_HD_LOT);
      auto& e = b.ev().u.hd_lot;
      e.program = -1;
      e.role = TERRA_LOT_ROLE_OTHER;
      if (evt->lot.service && evt->lot.service->audio_component) {
        e.program = evt->lot.service->audio_component->audio.port;
      }
      uint32_t component_mime = 0;
      if (evt->lot.component) {
        e.port = evt->lot.component->data.port;
        component_mime = evt->lot.component->data.mime;
      } else {
        e.port = evt->lot.port;
      }
      if (component_mime == NRSC5_MIME_PRIMARY_IMAGE) e.role = TERRA_LOT_ROLE_PRIMARY_IMAGE;
      else if (component_mime == NRSC5_MIME_STATION_LOGO) e.role = TERRA_LOT_ROLE_STATION_LOGO;
      else if (component_mime == NRSC5_MIME_TTN_STM_TRAFFIC) e.role = TERRA_LOT_ROLE_TRAFFIC;
      else if (component_mime == NRSC5_MIME_TTN_STM_WEATHER) e.role = TERRA_LOT_ROLE_WEATHER;
      e.lot_id = static_cast<int32_t>(evt->lot.lot);
      e.mime = evt->lot.mime;
      e.size = static_cast<int32_t>(evt->lot.size);
      e.expiry_unix = to_unix(evt->lot.expiry_utc);
      e.is_image = looks_like_image(evt->lot.data, evt->lot.size) ? 1 : 0;
      b.set_string(&e.name, evt->lot.name);
      // Images, plus small text files (the weather service describes its radar
      // area in one). Other payloads (TPEG etc.) are reported by size only.
      const bool small_text = evt->lot.size <= kMaxTextLotBytes &&
                              (evt->lot.mime == NRSC5_MIME_TEXT || e.role == TERRA_LOT_ROLE_WEATHER);
      if (e.is_image || small_text) b.set_bytes(&e.data, evt->lot.data, evt->lot.size);
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_STATION_ID: {
      EventBuilder b(TERRA_EVENT_HD_STATION_ID);
      b.set_string(&b.ev().u.hd_station.country_code, evt->station_id.country_code);
      b.ev().u.hd_station.fcc_facility_id = evt->station_id.fcc_facility_id;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_STATION_NAME: {
      EventBuilder b(TERRA_EVENT_HD_STATION_NAME);
      set_text(b, &b.ev().u.hd_station.text, evt->station_name.name);
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_STATION_SLOGAN: {
      EventBuilder b(TERRA_EVENT_HD_STATION_SLOGAN);
      set_text(b, &b.ev().u.hd_station.text, evt->station_slogan.slogan);
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_STATION_MESSAGE: {
      EventBuilder b(TERRA_EVENT_HD_STATION_MESSAGE);
      set_text(b, &b.ev().u.hd_station.text, evt->station_message.message);
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_STATION_LOCATION: {
      EventBuilder b(TERRA_EVENT_HD_STATION_LOCATION);
      b.ev().u.hd_station.latitude = evt->station_location.latitude;
      b.ev().u.hd_station.longitude = evt->station_location.longitude;
      b.ev().u.hd_station.altitude_m = evt->station_location.altitude;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_AUDIO_SERVICE_DESCRIPTOR: {
      EventBuilder b(TERRA_EVENT_HD_PROGRAM);
      auto& e = b.ev().u.hd_program;
      e.program = static_cast<int32_t>(evt->asd.program);
      e.access = static_cast<int32_t>(evt->asd.access);
      e.program_type = static_cast<int32_t>(evt->asd.type);
      const char* name = nullptr;
      nrsc5_program_type_name(evt->asd.type, &name);
      b.set_string(&e.program_type_name, name);
      e.blend_control = -1;
      e.common_delay = -1;
      e.latency = -1;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_AUDIO_SERVICE: {
      EventBuilder b(TERRA_EVENT_HD_PROGRAM);
      auto& e = b.ev().u.hd_program;
      e.program = static_cast<int32_t>(evt->audio_service.program);
      e.access = static_cast<int32_t>(evt->audio_service.access);
      e.program_type = static_cast<int32_t>(evt->audio_service.type);
      const char* name = nullptr;
      nrsc5_program_type_name(evt->audio_service.type, &name);
      b.set_string(&e.program_type_name, name);
      e.blend_control = static_cast<int32_t>(evt->audio_service.blend_control);
      e.common_delay = static_cast<int32_t>(evt->audio_service.common_delay);
      e.latency = static_cast<int32_t>(evt->audio_service.latency);
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_EMERGENCY_ALERT: {
      EventBuilder b(TERRA_EVENT_HD_ALERT);
      b.set_string(&b.ev().u.hd_alert.message, evt->emergency_alert.message);
      b.ev().u.hd_alert.category1 = evt->emergency_alert.category1;
      b.ev().u.hd_alert.category2 = evt->emergency_alert.category2;
      events_.emit(b);
      break;
    }
    case NRSC5_EVENT_HERE_IMAGE: {
      EventBuilder b(TERRA_EVENT_HD_HERE_IMAGE);
      auto& e = b.ev().u.hd_here_image;
      e.image_type = evt->here_image.image_type;
      e.seq = evt->here_image.seq;
      e.n1 = evt->here_image.n1;
      e.n2 = evt->here_image.n2;
      e.latitude1 = evt->here_image.latitude1;
      e.longitude1 = evt->here_image.longitude1;
      e.latitude2 = evt->here_image.latitude2;
      e.longitude2 = evt->here_image.longitude2;
      e.size = static_cast<int32_t>(evt->here_image.size);
      e.time_unix = to_unix(evt->here_image.time_utc);
      b.set_string(&e.name, evt->here_image.name);
      if (looks_like_image(evt->here_image.data, evt->here_image.size)) {
        b.set_bytes(&e.data, evt->here_image.data, evt->here_image.size);
      }
      events_.emit(b);
      break;
    }
    default:
      break;
  }
}

}  // namespace terra
