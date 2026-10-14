import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/radio_types.dart';
import '../radio/band_plan.dart';

class Preset {
  const Preset({required this.frequencyHz, this.program = 0, this.name});

  factory Preset.fromJson(Map<String, Object?> json) => Preset(
    frequencyHz: json['f']! as int,
    program: (json['p'] as int?) ?? 0,
    name: json['n'] as String?,
  );

  final int frequencyHz;
  final int program;
  final String? name;

  bool matches(int frequencyHz, int program) =>
      this.frequencyHz == frequencyHz && this.program == program;

  Preset withName(String? name) =>
      Preset(frequencyHz: frequencyHz, program: program, name: name);

  Map<String, Object?> toJson() => {
    'f': frequencyHz,
    if (program != 0) 'p': program,
    'n': ?name,
  };
}

/// A station found by a band scan (or learned while listening).
class KnownStation {
  const KnownStation({
    required this.frequencyHz,
    this.name,
    this.hd = false,
    this.programs = 1,
    this.snrDb,
    this.category,
  });

  factory KnownStation.fromJson(Map<String, Object?> json) => KnownStation(
    frequencyHz: json['f']! as int,
    name: json['n'] as String?,
    hd: (json['hd'] as bool?) ?? false,
    programs: (json['p'] as int?) ?? 1,
    snrDb: (json['s'] as num?)?.toDouble(),
    category: json['c'] as String?,
  );

  final int frequencyHz;
  final String? name;
  final bool hd;

  /// Number of HD programs (HD1..HDn).
  final int programs;
  final double? snrDb;

  /// RDS/RBDS or HD program type of the main program, when the scan learned one.
  final String? category;

  KnownStation copyWith({
    String? name,
    bool? hd,
    int? programs,
    double? snrDb,
    String? category,
  }) => KnownStation(
    frequencyHz: frequencyHz,
    name: name ?? this.name,
    hd: hd ?? this.hd,
    programs: programs ?? this.programs,
    snrDb: snrDb ?? this.snrDb,
    category: category ?? this.category,
  );

  Map<String, Object?> toJson() => {
    'f': frequencyHz,
    'n': ?name,
    if (hd) 'hd': true,
    if (programs > 1) 'p': programs,
    if (snrDb != null) 's': double.parse(snrDb!.toStringAsFixed(1)),
    'c': ?category,
  };
}

enum SourceKind { usb, rtlTcp }

enum AppTheme { system, light, dark }

/// Which edge a short preset page sits against. A full page of five always
/// spans the width. The Listen bank always shows five slots, so this is kept
/// for saved settings.
enum PresetSide { left, center, right }

/// Previous and next buttons beside the presets. Swiping works in every mode.
enum PresetArrows {
  /// Shown when the preset row has room for them beside five presets.
  auto,
  on,
  off;

  String get label => switch (this) {
    PresetArrows.auto => 'Auto',
    PresetArrows.on => 'On',
    PresetArrows.off => 'Off',
  };

  /// Versions before the dropdown saved a switch; on meant [auto].
  static PresetArrows fromJson(Object? value) => switch (value) {
    true => PresetArrows.auto,
    false => PresetArrows.off,
    final String name =>
      PresetArrows.values.asNameMap()[name] ?? PresetArrows.auto,
    _ => PresetArrows.auto,
  };
}

/// What the next and previous media keys do.
enum MediaKeys {
  presets,
  scan,
  step;

  String get label => switch (this) {
    MediaKeys.presets => 'Presets up/down',
    MediaKeys.scan => 'Scan up/down',
    MediaKeys.step => 'Step up/down',
  };
}

/// What a held seek stops on. A tap still jumps the scanned station list.
enum SeekScan {
  fm,
  hd;

  String get label => switch (this) {
    SeekScan.fm => 'FM',
    SeekScan.hd => 'HD only',
  };
}

/// How much of the radio log to keep. Null in [RadioSettings] means Debug
/// while debugging and Info otherwise.
enum LogDetail {
  error,
  warning,
  info,
  debug,
  trace;

  String get label => switch (this) {
    LogDetail.error => 'Errors',
    LogDetail.warning => 'Warnings',
    LogDetail.info => 'Info',
    LogDetail.debug => 'Debug',
    LogDetail.trace => 'Trace',
  };
}

/// How much of the space above the presets the station block uses.
const stationScaleMin = 0.7;
const stationScaleMax = 1.0;

/// Multiplier for the preset row. 1 is already large enough for a finger.
const presetScaleMin = 0.85;
const presetScaleMax = 1.5;

const presetCountDefault = 15;
const presetCountMin = 3;
const presetCountMax = 30;
const presetsPerPageDefault = 5;
const presetsPerPageMin = 3;
const presetsPerPageMax = 10;

int clampPresetCount(int count) => count.clamp(presetCountMin, presetCountMax);

int clampPresetsPerPage(int count) =>
    count.clamp(presetsPerPageMin, presetsPerPageMax);

/// How many carousel pages [count] presets make at [perPage] each.
int presetPageCount(int count, int perPage) {
  final n = clampPresetCount(count);
  final per = clampPresetsPerPage(perPage);
  final pages = (n + per - 1) ~/ per;
  return pages < 1 ? 1 : pages;
}

/// The visible preset slots, empty ones included, so a saved bank keeps its holes.
/// Presets past [count] stay stored and show again if the bank grows.
List<Preset?> presetSlots(List<Preset?> presets, int count) {
  final n = clampPresetCount(count);
  return List<Preset?>.generate(
    n,
    (i) => i < presets.length ? presets[i] : null,
  );
}

double clampStationScale(double scale) =>
    scale.clamp(stationScaleMin, stationScaleMax).toDouble();

double clampPresetScale(double scale) =>
    scale.clamp(presetScaleMin, presetScaleMax).toDouble();

/// Analog mute threshold in dB of carrier-to-noise. Matches
/// `TERRA_DEFAULT_SQUELCH_DB` in terra_core.h. [squelchOffDb] leaves FM open.
const defaultSquelchDb = 7;
const squelchOffDb = -1;
const squelchMinDb = 0;
const squelchMaxDb = 30;

/// HD audio level relative to analog FM. 1 matches FM; HD is often mastered quieter.
const hdVolumeMin = 0.5;
const hdVolumeMax = 2.0;

double clampHdVolume(double level) =>
    level.clamp(hdVolumeMin, hdVolumeMax).toDouble();

int clampSquelchDb(int thresholdDb) => thresholdDb < 0
    ? squelchOffDb
    : thresholdDb.clamp(squelchMinDb, squelchMaxDb);

const _unset = Object();

class RadioSettings {
  const RadioSettings({
    this.band = BandPlan.northAmerica,
    this.lastFrequencyHz,
    this.lastProgram = 0,
    this.audioMode = AudioMode.auto,
    this.gainMode = GainMode.auto,
    this.manualGainTenthDb = 297,
    this.ppm = 0,
    this.biasTee = false,
    this.blendAlignmentMs = 2250,
    this.squelchDb = defaultSquelchDb,
    this.volume = 1.0,
    this.hdVolume = 1.0,
    this.presets = const [],
    this.stations = const [],
    this.gainCache = const {},
    this.sourceKind = SourceKind.usb,
    this.rtlTcpHost = '192.168.1.10',
    this.rtlTcpPort = 1234,
    this.autoConnect = true,
    this.downloadLogos = true,
    this.seekScan = SeekScan.fm,
    this.mediaKeys = MediaKeys.presets,
    this.uiScale,
    this.theme = AppTheme.system,
    this.stationScale = stationScaleMax,
    this.presetScale = 1,
    this.presetCount = presetCountDefault,
    this.presetsPerPage = presetsPerPageDefault,
    this.presetSide = PresetSide.center,
    this.presetArrows = PresetArrows.auto,
    this.logLevel,
  });

  factory RadioSettings.fromJson(Map<String, Object?> j) {
    const d = RadioSettings();
    return RadioSettings(
      band: BandPlan.fromName(j['band'] as String?),
      lastFrequencyHz: j['lastFrequencyHz'] as int?,
      lastProgram: (j['lastProgram'] as int?) ?? 0,
      audioMode: AudioMode.values.asNameMap()[j['audioMode']] ?? d.audioMode,
      gainMode: GainMode.values.asNameMap()[j['gainMode']] ?? d.gainMode,
      manualGainTenthDb:
          (j['manualGainTenthDb'] as int?) ?? d.manualGainTenthDb,
      ppm: (j['ppm'] as int?) ?? 0,
      biasTee: (j['biasTee'] as bool?) ?? false,
      blendAlignmentMs: (j['blendAlignmentMs'] as int?) ?? d.blendAlignmentMs,
      squelchDb: clampSquelchDb((j['squelchDb'] as int?) ?? d.squelchDb),
      volume: ((j['volume'] as num?) ?? 1.0).toDouble(),
      hdVolume: clampHdVolume(
        (j['hdVolume'] as num?)?.toDouble() ?? d.hdVolume,
      ),
      presets: [
        for (final p in (j['presets'] as List<Object?>?) ?? const <Object?>[])
          p is Map ? Preset.fromJson(p.cast()) : null,
      ],
      stations: [
        for (final s in (j['stations'] as List<Object?>?) ?? const [])
          KnownStation.fromJson((s! as Map).cast()),
      ],
      gainCache: {
        for (final e
            in ((j['gainCache'] as Map<String, Object?>?) ?? const {}).entries)
          int.parse(e.key): e.value! as int,
      },
      sourceKind:
          SourceKind.values.asNameMap()[j['sourceKind']] ?? d.sourceKind,
      rtlTcpHost: (j['rtlTcpHost'] as String?) ?? d.rtlTcpHost,
      rtlTcpPort: (j['rtlTcpPort'] as int?) ?? d.rtlTcpPort,
      autoConnect: (j['autoConnect'] as bool?) ?? true,
      downloadLogos: (j['downloadLogos'] as bool?) ?? true,
      seekScan:
          SeekScan.values.asNameMap()[j['seekScan'] as String?] ?? d.seekScan,
      mediaKeys:
          MediaKeys.values.asNameMap()[j['mediaKeys'] as String?] ??
          d.mediaKeys,
      uiScale: (j['uiScale'] as num?)?.toDouble(),
      theme: AppTheme.values.asNameMap()[j['theme']] ?? d.theme,
      stationScale: clampStationScale(
        (j['stationScale'] as num?)?.toDouble() ?? d.stationScale,
      ),
      presetScale: clampPresetScale(
        (j['presetScale'] as num?)?.toDouble() ?? d.presetScale,
      ),
      presetCount: clampPresetCount(
        (j['presetCount'] as int?) ?? d.presetCount,
      ),
      presetsPerPage: clampPresetsPerPage(
        (j['presetsPerPage'] as int?) ?? d.presetsPerPage,
      ),
      presetSide:
          PresetSide.values.asNameMap()[j['presetSide']] ?? d.presetSide,
      presetArrows: PresetArrows.fromJson(j['presetArrows']),
      logLevel: LogDetail.values.asNameMap()[j['logLevel'] as String?],
    );
  }

  final BandPlan band;
  final int? lastFrequencyHz;
  final int lastProgram;
  final AudioMode audioMode;
  final GainMode gainMode;
  final int manualGainTenthDb;
  final int ppm;
  final bool biasTee;

  /// > 0 delays HD, < 0 delays analog.
  final int blendAlignmentMs;

  /// Analog FM mute level in dB CNR. Negative ([squelchOffDb]) disables it.
  final int squelchDb;
  final double volume;

  /// HD playback level relative to analog FM. 1 matches FM.
  final double hdVolume;

  /// Preset bank. Shorter lists are the first slots; null entries are empty.
  /// Entries past [presetCount] are hidden until the bank grows again.
  final List<Preset?> presets;

  /// How many slots are shown. Defaults to three pages of five.
  final int presetCount;

  /// Slots on one carousel page.
  final int presetsPerPage;

  List<Preset?> get slots => presetSlots(presets, presetCount);

  /// Sorted by frequency.
  final List<KnownStation> stations;

  /// Frequency (Hz) -> last converged auto gain (tenths of dB).
  final Map<int, int> gainCache;
  final SourceKind sourceKind;
  final String rtlTcpHost;
  final int rtlTcpPort;

  /// Open the last source on launch (and on USB attach).
  final bool autoConnect;

  /// Look up a RadioDNS logo when tuning or scanning finds a station with none.
  final bool downloadLogos;

  /// Held seek: FM stops on a carrier, HD only waits for an HD lock.
  final SeekScan seekScan;

  /// Next and previous on the lock screen, notification, and media keys.
  final MediaKeys mediaKeys;

  /// Display size multiplier; null picks one for the screen.
  final double? uiScale;
  final AppTheme theme;

  /// 1 fills the space above the presets; lower leaves a margin.
  final double stationScale;

  /// Preset row size. 1 is sized for a finger.
  final double presetScale;

  /// Where a page of fewer than five presets sits.
  final PresetSide presetSide;

  /// Previous and next buttons beside the preset pages. Swiping works either way.
  final PresetArrows presetArrows;

  /// Null follows the build: Debug while debugging, Info otherwise.
  final LogDetail? logLevel;

  Map<String, Object?> toJson() => {
    'band': band.name,
    'lastFrequencyHz': ?lastFrequencyHz,
    'lastProgram': lastProgram,
    'audioMode': audioMode.name,
    'gainMode': gainMode.name,
    'manualGainTenthDb': manualGainTenthDb,
    'ppm': ppm,
    'biasTee': biasTee,
    'blendAlignmentMs': blendAlignmentMs,
    'squelchDb': squelchDb,
    'volume': volume,
    'hdVolume': hdVolume,
    'presets': [for (final p in slots) p?.toJson()],
    'stations': [for (final s in stations) s.toJson()],
    'gainCache': {for (final e in gainCache.entries) '${e.key}': e.value},
    'sourceKind': sourceKind.name,
    'rtlTcpHost': rtlTcpHost,
    'rtlTcpPort': rtlTcpPort,
    'autoConnect': autoConnect,
    'downloadLogos': downloadLogos,
    'seekScan': seekScan.name,
    'mediaKeys': mediaKeys.name,
    'uiScale': ?uiScale,
    'theme': theme.name,
    'stationScale': stationScale,
    'presetScale': presetScale,
    'presetCount': presetCount,
    'presetsPerPage': presetsPerPage,
    'presetSide': presetSide.name,
    'presetArrows': presetArrows.name,
    'logLevel': ?logLevel?.name,
  };

  RadioSettings copyWith({
    BandPlan? band,
    int? lastFrequencyHz,
    int? lastProgram,
    AudioMode? audioMode,
    GainMode? gainMode,
    int? manualGainTenthDb,
    int? ppm,
    bool? biasTee,
    int? blendAlignmentMs,
    int? squelchDb,
    double? volume,
    double? hdVolume,
    List<Preset?>? presets,
    List<KnownStation>? stations,
    Map<int, int>? gainCache,
    SourceKind? sourceKind,
    String? rtlTcpHost,
    int? rtlTcpPort,
    bool? autoConnect,
    bool? downloadLogos,
    SeekScan? seekScan,
    MediaKeys? mediaKeys,
    Object? uiScale = _unset,
    AppTheme? theme,
    double? stationScale,
    double? presetScale,
    int? presetCount,
    int? presetsPerPage,
    PresetSide? presetSide,
    PresetArrows? presetArrows,
    LogDetail? logLevel,
  }) {
    return RadioSettings(
      band: band ?? this.band,
      lastFrequencyHz: lastFrequencyHz ?? this.lastFrequencyHz,
      lastProgram: lastProgram ?? this.lastProgram,
      audioMode: audioMode ?? this.audioMode,
      gainMode: gainMode ?? this.gainMode,
      manualGainTenthDb: manualGainTenthDb ?? this.manualGainTenthDb,
      ppm: ppm ?? this.ppm,
      biasTee: biasTee ?? this.biasTee,
      blendAlignmentMs: blendAlignmentMs ?? this.blendAlignmentMs,
      squelchDb: squelchDb ?? this.squelchDb,
      volume: volume ?? this.volume,
      hdVolume: hdVolume ?? this.hdVolume,
      presets: presets ?? this.presets,
      stations: stations ?? this.stations,
      gainCache: gainCache ?? this.gainCache,
      sourceKind: sourceKind ?? this.sourceKind,
      rtlTcpHost: rtlTcpHost ?? this.rtlTcpHost,
      rtlTcpPort: rtlTcpPort ?? this.rtlTcpPort,
      autoConnect: autoConnect ?? this.autoConnect,
      downloadLogos: downloadLogos ?? this.downloadLogos,
      seekScan: seekScan ?? this.seekScan,
      mediaKeys: mediaKeys ?? this.mediaKeys,
      uiScale: uiScale == _unset ? this.uiScale : uiScale as double?,
      theme: theme ?? this.theme,
      stationScale: stationScale ?? this.stationScale,
      presetScale: presetScale ?? this.presetScale,
      presetCount: presetCount ?? this.presetCount,
      presetsPerPage: presetsPerPage ?? this.presetsPerPage,
      presetSide: presetSide ?? this.presetSide,
      presetArrows: presetArrows ?? this.presetArrows,
      logLevel: logLevel ?? this.logLevel,
    );
  }
}

/// Minimal key-value persistence so tests can swap in [MemoryKeyValueStore].
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

class MemoryKeyValueStore implements KeyValueStore {
  final values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

class PrefsKeyValueStore implements KeyValueStore {
  PrefsKeyValueStore._(this._prefs);

  static Future<PrefsKeyValueStore> open() async => PrefsKeyValueStore._(
    await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    ),
  );

  final SharedPreferencesWithCache _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
}

class SettingsStore {
  SettingsStore(this._store);

  static const _key = 'terra.settings.v1';
  final KeyValueStore _store;

  RadioSettings load() {
    final raw = _store.getString(_key);
    if (raw == null) return const RadioSettings();
    try {
      return RadioSettings.fromJson((jsonDecode(raw) as Map).cast());
    } on Object {
      return const RadioSettings();
    }
  }

  Future<void> save(RadioSettings settings) =>
      _store.setString(_key, jsonEncode(settings.toJson()));
}
