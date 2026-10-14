/*
 * terra_core: HD (NRSC-5) + analog FM receiver engine for USB tuners.
 *
 * Threading: all terra_engine_* functions are safe to call from one control
 * thread (the Dart isolate). Events are delivered on internal threads through
 * the callback passed to terra_engine_create(); the receiver owns each event
 * and must release it with terra_event_free().
 *
 * Copyright (C) 2026 Terra FM contributors. GPL-3.0-or-later.
 */
#ifndef TERRA_CORE_H
#define TERRA_CORE_H

#include <stdint.h>

#if defined(_WIN32)
#define TERRA_API __declspec(dllexport)
#else
#define TERRA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define TERRA_API_VERSION 1

/* IQ sample rate every source delivers: unsigned 8-bit interleaved I/Q. */
#define TERRA_IQ_SAMPLE_RATE 1488375
#define TERRA_AUDIO_SAMPLE_RATE 44100

/* nrsc5 delivers HD audio ~2.25 s ahead of the station's (diversity-delayed)
 * analog audio; delaying HD by this much makes HD/analog blends seamless. */
#define TERRA_DEFAULT_BLEND_ALIGNMENT_MS 2250

/* Analog FM mute threshold, in dB of carrier-to-noise. The receiver mutes
 * below this and opens 2 dB above it. TERRA_SQUELCH_OFF disables muting. */
#define TERRA_SQUELCH_OFF (-1)
#define TERRA_SQUELCH_MIN_DB 0
#define TERRA_SQUELCH_MAX_DB 30
#define TERRA_DEFAULT_SQUELCH_DB 7

/* ------------------------------------------------------------------------ */
/* Enumerations                                                              */
/* ------------------------------------------------------------------------ */

typedef enum {
  TERRA_SOURCE_RTLSDR_FD = 1,    /* Android: fd from UsbDeviceConnection */
  TERRA_SOURCE_RTLSDR_INDEX = 2, /* Desktop: librtlsdr device index */
  TERRA_SOURCE_RTL_TCP = 3,      /* rtl_tcp server */
  TERRA_SOURCE_FILE = 4,         /* Raw cu8 capture at TERRA_IQ_SAMPLE_RATE */
} terra_source_kind;

typedef enum {
  TERRA_AUDIO_MODE_AUTO = 0,    /* HD when decodable, analog FM otherwise (HD1) */
  TERRA_AUDIO_MODE_DIGITAL = 1, /* HD only */
  TERRA_AUDIO_MODE_ANALOG = 2,  /* Analog FM only */
} terra_audio_mode;

typedef enum {
  TERRA_GAIN_AUTO = 0,         /* Software AGC with MER/CNR refinement */
  TERRA_GAIN_MANUAL = 1,       /* Fixed tuner gain */
  TERRA_GAIN_HARDWARE_AGC = 2, /* Tuner's own AGC */
} terra_gain_mode;

typedef enum {
  TERRA_SOURCE_STATE_CLOSED = 0,
  TERRA_SOURCE_STATE_OPENING = 1,
  TERRA_SOURCE_STATE_STREAMING = 2,
  TERRA_SOURCE_STATE_ENDED = 3, /* file source reached EOF */
  TERRA_SOURCE_STATE_LOST = 4,  /* device unplugged / connection dropped */
  TERRA_SOURCE_STATE_ERROR = 5,
} terra_source_state;

typedef enum {
  TERRA_AUDIO_SOURCE_NONE = 0,
  TERRA_AUDIO_SOURCE_HD = 1,
  TERRA_AUDIO_SOURCE_ANALOG = 2,
} terra_audio_source;

typedef enum {
  TERRA_LOT_ROLE_OTHER = 0,
  TERRA_LOT_ROLE_PRIMARY_IMAGE = 1, /* album / program art */
  TERRA_LOT_ROLE_STATION_LOGO = 2,
  TERRA_LOT_ROLE_TRAFFIC = 3, /* TTN traffic service (TMT_ map tiles) */
  TERRA_LOT_ROLE_WEATHER = 4, /* TTN weather service (DWRO_ radar, DWRI_ info) */
} terra_lot_role;

typedef enum {
  TERRA_LOG_DEBUG = 0,
  TERRA_LOG_INFO = 1,
  TERRA_LOG_WARN = 2,
  TERRA_LOG_ERROR = 3,
} terra_log_level;

typedef enum {
  TERRA_EVENT_LOG = 1,
  TERRA_EVENT_SOURCE_STATE = 2,
  TERRA_EVENT_DEVICE_INFO = 3,
  TERRA_EVENT_TUNED = 4,
  TERRA_EVENT_SIGNAL = 5,
  TERRA_EVENT_SPECTRUM = 6,
  TERRA_EVENT_GAIN = 7,
  TERRA_EVENT_HD_SYNC = 20,
  TERRA_EVENT_HD_QUALITY = 21,
  TERRA_EVENT_HD_STATION_ID = 22,
  TERRA_EVENT_HD_STATION_NAME = 23,
  TERRA_EVENT_HD_STATION_SLOGAN = 24,
  TERRA_EVENT_HD_STATION_MESSAGE = 25,
  TERRA_EVENT_HD_STATION_LOCATION = 26,
  TERRA_EVENT_HD_PROGRAM = 27,
  TERRA_EVENT_HD_ID3 = 28,
  TERRA_EVENT_HD_LOT = 29,
  TERRA_EVENT_HD_ALERT = 30,
  TERRA_EVENT_HD_HERE_IMAGE = 31,
  TERRA_EVENT_FM_STATUS = 40,
  TERRA_EVENT_RDS = 41,
  TERRA_EVENT_AUDIO_STATUS = 50,
} terra_event_type;

/* ------------------------------------------------------------------------ */
/* Event payloads. Strings are UTF-8, NUL-terminated, may be NULL.           */
/* ------------------------------------------------------------------------ */

typedef struct {
  int32_t level; /* terra_log_level */
  const char *tag;
  const char *message;
} terra_evt_log;

typedef struct {
  int32_t state; /* terra_source_state */
  int32_t error_code;
  const char *message;
} terra_evt_source_state;

typedef struct {
  const char *description; /* e.g. "RTL-SDR Blog V4 (R828D)" */
  const char *tuner;       /* tuner chip name */
  const int32_t *gains;    /* available tuner gains, tenths of dB */
  int32_t gain_count;
  int32_t supports_bias_tee;
} terra_evt_device_info;

typedef struct {
  uint32_t frequency_hz;
} terra_evt_tuned;

typedef struct {
  float rms_dbfs;     /* whole-capture IQ RMS */
  float peak_dbfs;
  float clip_ratio;   /* fraction of samples at full scale */
  float channel_dbfs; /* power within ±100 kHz of the tuned frequency */
  float noise_dbfs;   /* noise floor estimate, same bandwidth */
  float snr_db;
  int32_t gain_tenth_db;
} terra_evt_signal;

typedef struct {
  uint32_t center_hz;
  uint32_t span_hz;
  const float *bins_db; /* bins_count values, lowest frequency first */
  int32_t bins_count;
} terra_evt_spectrum;

typedef struct {
  int32_t mode; /* terra_gain_mode */
  int32_t gain_tenth_db;
  int32_t converged; /* 1 once auto gain settled for this frequency */
} terra_evt_gain;

typedef struct {
  int32_t synced;
  float freq_offset_hz;
  int32_t psmi;
} terra_evt_hd_sync;

typedef struct {
  float mer_lower_db;
  float mer_upper_db;
  float ber;
} terra_evt_hd_quality;

typedef struct {
  const char *country_code;
  int32_t fcc_facility_id;
  const char *text; /* name / slogan / message, depending on event type */
  float latitude;
  float longitude;
  int32_t altitude_m;
} terra_evt_hd_station;

typedef struct {
  int32_t program; /* 0 = HD1 */
  int32_t access;  /* 0 public, 1 restricted */
  int32_t program_type;
  const char *program_type_name;
  int32_t blend_control; /* -1 unknown, else NRSC5_BLEND_* */
  int32_t common_delay;  /* audio frames, -1 unknown */
  int32_t latency;       /* audio frames, -1 unknown */
} terra_evt_hd_program;

typedef struct {
  int32_t program;
  const char *title;
  const char *artist;
  const char *album;
  const char *genre;
  const char *comment;
  const char *ufid_owner;
  const char *ufid_id;
  uint32_t xhdr_mime;
  int32_t xhdr_param; /* -1 when absent */
  int32_t xhdr_lot;
} terra_evt_hd_id3;

typedef struct {
  int32_t program; /* -1 when not tied to an audio program */
  int32_t role;    /* terra_lot_role */
  int32_t lot_id;
  int32_t port;
  uint32_t mime;   /* NRSC5_MIME_JPEG / NRSC5_MIME_PNG / ... */
  const char *name;
  const uint8_t *data; /* images and small text files; NULL for other payloads */
  int32_t size;
  int64_t expiry_unix; /* seconds, 0 if unknown */
  int32_t is_image;    /* data starts with a JPEG/PNG/GIF signature */
} terra_evt_hd_lot;

typedef struct {
  const char *message;
  int32_t category1;
  int32_t category2;
} terra_evt_hd_alert;

typedef struct {
  int32_t image_type; /* 8 traffic, 13 weather */
  int32_t seq;
  int32_t n1; /* traffic: tile 1..9; weather: sequence */
  int32_t n2; /* traffic: tile count (9); weather: sequence */
  float latitude1, longitude1, latitude2, longitude2; /* north, west, south, east edges */
  const char *name;
  const uint8_t *data;
  int32_t size;
  int64_t time_unix; /* broadcast time of the map, seconds UTC, 0 if unknown */
} terra_evt_hd_here_image;

typedef struct {
  float cnr_db;        /* carrier-to-noise estimate in the channel filter */
  float pilot_level;   /* coherent 19 kHz pilot amplitude (0..~0.05) */
  int32_t stereo;      /* pilot locked */
  float stereo_blend;  /* 0 mono .. 1 full separation */
  int32_t squelched;
  int32_t rds_synced;
  float rds_block_error_rate;
} terra_evt_fm_status;

typedef struct {
  int32_t pi;  /* -1 unknown */
  int32_t pty; /* -1 unknown */
  int32_t tp;
  int32_t ta;
  int32_t ms;
  const char *ps; /* 8-char program service name, NULL until complete */
  const char *rt; /* RadioText, NULL until complete */
} terra_evt_rds;

typedef struct {
  int32_t active;        /* terra_audio_source currently heard */
  int32_t hd_available;  /* HD audio for the selected program is flowing */
  int32_t program;
  int32_t mode;          /* terra_audio_mode */
  float buffer_ms;       /* output buffer depth */
  int32_t underruns;     /* cumulative */
  float level_left_db;   /* output peak level, dBFS */
  float level_right_db;
  int32_t device_running;
  int32_t device_sample_rate;
} terra_evt_audio_status;

typedef struct terra_event {
  int32_t type; /* terra_event_type */
  int64_t timestamp_us;
  union terra_event_payload {
    terra_evt_log log;
    terra_evt_source_state source_state;
    terra_evt_device_info device_info;
    terra_evt_tuned tuned;
    terra_evt_signal signal;
    terra_evt_spectrum spectrum;
    terra_evt_gain gain;
    terra_evt_hd_sync hd_sync;
    terra_evt_hd_quality hd_quality;
    terra_evt_hd_station hd_station;
    terra_evt_hd_program hd_program;
    terra_evt_hd_id3 hd_id3;
    terra_evt_hd_lot hd_lot;
    terra_evt_hd_alert hd_alert;
    terra_evt_hd_here_image hd_here_image;
    terra_evt_fm_status fm_status;
    terra_evt_rds rds;
    terra_evt_audio_status audio_status;
  } u;
} terra_event;

typedef void (*terra_event_callback)(void *user_data, terra_event *event);

/* Dart's NativeApi.postCObject: posts a Dart_CObject to a native port and
 * returns 0 when the port is closed. */
typedef int8_t (*terra_post_message)(int64_t port, void *message);

/* Optional PCM tap: interleaved stereo float at TERRA_AUDIO_SAMPLE_RATE,
 * exactly what goes to the speaker (pre-volume). Called on the DSP thread. */
typedef void (*terra_pcm_callback)(void *user_data, const float *frames, int32_t frame_count);

typedef struct {
  int32_t kind; /* terra_source_kind */
  int32_t fd;           /* TERRA_SOURCE_RTLSDR_FD */
  int32_t device_index; /* TERRA_SOURCE_RTLSDR_INDEX */
  const char *host;     /* TERRA_SOURCE_RTL_TCP */
  int32_t port;
  const char *path;     /* TERRA_SOURCE_FILE */
  int32_t realtime;     /* FILE: 1 = pace at real time, 0 = as fast as possible */
  int32_t loop;         /* FILE: restart at EOF */
} terra_source_config;

typedef struct terra_engine terra_engine;

/* ------------------------------------------------------------------------ */
/* API                                                                       */
/* ------------------------------------------------------------------------ */

TERRA_API int32_t terra_api_version(void);
TERRA_API const char *terra_version_string(void);

TERRA_API terra_engine *terra_engine_create(terra_event_callback callback, void *user_data);
/* Like terra_engine_create, but events are queued for terra_engine_poll_event.
 * The port is only probed to learn whether its isolate is still alive. The
 * DSP thread never calls into the VM, so a Flutter hot restart can tear the
 * isolate down without a use-after-free. The engine keeps running until
 * terra_engine_destroy_orphans() tears it down. */
TERRA_API terra_engine *terra_engine_create_for_port(terra_post_message post, int64_t port);
/* Next queued event address, or 0. The caller frees it with terra_event_free. */
TERRA_API int64_t terra_engine_poll_event(terra_engine *engine);
/* Stops everything and joins internal threads. No callbacks after return. */
TERRA_API void terra_engine_destroy(terra_engine *engine);
/* Destroys every port engine whose port has closed, releasing its device.
 * Call before creating a new engine after a restart. Blocks while their
 * threads stop. Returns how many were destroyed. */
TERRA_API int32_t terra_engine_destroy_orphans(void);

/* Opens the source and starts streaming/decoding. Returns 0 on success. */
TERRA_API int32_t terra_engine_open(terra_engine *engine, const terra_source_config *config);
TERRA_API void terra_engine_close(terra_engine *engine);

/* gain_hint_tenth_db: last good gain for this frequency, or -1. Without an
 * open source this only records the frequency/hint for the next open(). */
TERRA_API int32_t terra_engine_tune(terra_engine *engine, uint32_t frequency_hz,
                                    int32_t gain_hint_tenth_db);
TERRA_API void terra_engine_set_program(terra_engine *engine, int32_t program);
TERRA_API void terra_engine_set_audio_mode(terra_engine *engine, int32_t mode);
TERRA_API void terra_engine_set_gain(terra_engine *engine, int32_t mode, int32_t gain_tenth_db);
TERRA_API void terra_engine_set_ppm(terra_engine *engine, int32_t ppm);
TERRA_API void terra_engine_set_bias_tee(terra_engine *engine, int32_t enabled);
TERRA_API void terra_engine_set_deemphasis_us(terra_engine *engine, int32_t microseconds);
/* Lines up HD and analog audio for blending: > 0 delays HD by that many ms,
 * < 0 delays analog instead. Default TERRA_DEFAULT_BLEND_ALIGNMENT_MS. */
TERRA_API void terra_engine_set_blend_alignment_ms(terra_engine *engine, int32_t milliseconds);
/* Analog FM squelch. threshold_db is the mute level (CNR, dB); the receiver
 * opens 2 dB above it. TERRA_SQUELCH_OFF disables muting. Out-of-range values
 * clamp to TERRA_SQUELCH_MIN_DB..TERRA_SQUELCH_MAX_DB. Default
 * TERRA_DEFAULT_SQUELCH_DB. HD audio is unaffected. */
TERRA_API void terra_engine_set_squelch_db(terra_engine *engine, int32_t threshold_db);
TERRA_API void terra_engine_set_volume(terra_engine *engine, float volume);
/* HD playback level relative to analog FM. 1 matches FM. Clamped to
 * 0.25..4. Applied to HD audio before it is blended with analog. */
TERRA_API void terra_engine_set_hd_level(terra_engine *engine, float level);
/* Starts/stops the audio output device. Decoding continues either way. */
TERRA_API void terra_engine_set_audio_enabled(terra_engine *engine, int32_t enabled);
TERRA_API void terra_engine_set_spectrum_enabled(terra_engine *engine, int32_t enabled);
TERRA_API void terra_engine_set_pcm_callback(terra_engine *engine, terra_pcm_callback callback,
                                             void *user_data);

TERRA_API void terra_event_free(terra_event *event);

/* Desktop USB enumeration (always 0 on Android, which uses file descriptors). */
TERRA_API int32_t terra_rtlsdr_device_count(void);
/* Writes a NUL-terminated description into buffer. Returns 0 on success. */
TERRA_API int32_t terra_rtlsdr_device_name(int32_t index, char *buffer, int32_t buffer_size);

#ifdef __cplusplus
}
#endif

#endif /* TERRA_CORE_H */
