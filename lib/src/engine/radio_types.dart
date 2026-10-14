/// Enumerations shared by the engine API, events and state. Values mirror
/// native/include/terra_core.h.
library;

enum AudioMode {
  /// HD when decodable, analog FM otherwise (HD1 only).
  auto(0),

  /// HD only; silence when HD drops.
  digital(1),

  /// Analog FM only.
  analog(2);

  const AudioMode(this.code);
  final int code;

  static AudioMode fromCode(int code) => values.firstWhere((m) => m.code == code, orElse: () => auto);
}

enum GainMode {
  /// Software AGC refined on HD MER / FM CNR.
  auto(0),
  manual(1),

  /// The tuner chip's own AGC.
  hardware(2);

  const GainMode(this.code);
  final int code;

  static GainMode fromCode(int code) => values.firstWhere((m) => m.code == code, orElse: () => auto);
}

enum SourceState {
  closed(0),
  opening(1),
  streaming(2),

  /// A file source reached its end.
  ended(3),

  /// Device unplugged or network connection dropped.
  lost(4),
  error(5);

  const SourceState(this.code);
  final int code;

  static SourceState fromCode(int code) => values.firstWhere((s) => s.code == code, orElse: () => error);
}

enum AudioSource {
  none(0),
  hd(1),
  analog(2);

  const AudioSource(this.code);
  final int code;

  static AudioSource fromCode(int code) => values.firstWhere((s) => s.code == code, orElse: () => none);
}

enum LotRole {
  other(0),
  primaryImage(1),
  stationLogo(2),

  /// TTN traffic data service (TMT_ map tiles).
  traffic(3),

  /// TTN weather data service (DWRO_ radar overlays, DWRI_ area info).
  weather(4);

  const LotRole(this.code);
  final int code;

  static LotRole fromCode(int code) => values.firstWhere((r) => r.code == code, orElse: () => other);
}

enum EngineLogLevel {
  debug(0),
  info(1),
  warn(2),
  error(3);

  const EngineLogLevel(this.code);
  final int code;

  static EngineLogLevel fromCode(int code) => values.firstWhere((l) => l.code == code, orElse: () => info);
}

enum HdStationText { name, slogan, message }
