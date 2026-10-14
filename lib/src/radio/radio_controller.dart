import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../devices/device_service.dart';
import '../engine/radio_engine.dart';
import '../engine/radio_event.dart';
import '../engine/radio_types.dart';
import '../engine/source_config.dart';
import '../logging/log_buffer.dart';
import '../settings/settings.dart';
import 'art_cache.dart';
import 'band_plan.dart';
import 'band_scan.dart';
import 'program_type.dart';
import 'radio_reducer.dart';
import 'radio_state.dart';
import 'radiodns.dart';
import 'rbds.dart';

enum ScanPhase { idle, sweeping, identifying }

class ScanStatus {
  const ScanStatus({
    this.phase = ScanPhase.idle,
    this.progress = 0,
    this.found = const [],
    this.error,
  });
  final ScanPhase phase;

  /// 0..1 within the current phase.
  final double progress;
  final List<KnownStation> found;

  /// Why the last scan stopped early. The previous station list is kept.
  final String? error;

  bool get active => phase != ScanPhase.idle;
}

/// App-level receiver logic on top of a [RadioEngine]: connection handling,
/// tuning, presets, scan/seek, and persistence of settings and gain hints.
class RadioController extends ChangeNotifier {
  RadioController({
    required this.engine,
    required SettingsStore settingsStore,
    required this.devices,
    ArtCache? artCache,
    RadioDns? radioDns,
    this._logs,
    this.reconnectInterval = const Duration(seconds: 2),
  }) : _settingsStore = settingsStore,
       _artCache = artCache ?? ArtCache(null),
       _radioDns = radioDns ?? RadioDns(),
       _settings = settingsStore.load() {
    _state = RadioState(
      program: _settings.lastProgram,
      audioMode: _settings.audioMode,
    );
    _engineSub = engine.events.listen(_onEvent);
    _logs?.setLevel(levelFor(_settings.logLevel));
  }

  /// Session log. INFO is the story (tune, lock, what is playing); FINE is
  /// the detail (RDS, gain steps, artwork). Debug builds show both.
  static final _log = Logger('radio');
  static final _nativeLog = Logger('native');

  final RadioEngine engine;
  final DeviceService devices;

  /// How often to look for a USB receiver that dropped out, where the
  /// platform cannot say when it is plugged back in.
  final Duration reconnectInterval;
  static const _reconnectFor = Duration(minutes: 2);
  int _reconnectToken = 0;
  bool _reconnecting = false;
  final SettingsStore _settingsStore;
  final ArtCache _artCache;
  final RadioDns _radioDns;
  final LogBuffer? _logs;
  bool _logoLookupOffline = false;
  Timer? _logoTimer;

  late RadioState _state;
  RadioSettings _settings;
  ScanStatus _scan = const ScanStatus();
  bool _audioEnabled = true;

  /// Chip selection overriding [RadioSettings.audioMode] until the next tune.
  bool _audioModeHeld = false;
  bool _seeking = false;

  /// Engine output muted for a held seek, while [audioEnabled] stays as the user left it.
  bool _seekMuted = false;
  bool _scanStopped = false;
  bool _deviceHeld = false;
  Uint8List? _cachedLogo;
  int _spectrumUsers = 0;
  int _generation = 0;
  Timer? _saveTimer;
  StreamSubscription<RadioEvent>? _engineSub;
  StreamSubscription<DeviceEvent>? _deviceSub;

  RadioState get state => _state;
  RadioSettings get settings => _settings;
  ScanStatus get scan => _scan;
  bool get audioEnabled => _audioEnabled;
  bool get seeking => _seeking;
  BandPlan get band => _settings.band;

  /// Waiting for a lost USB receiver to come back.
  bool get reconnecting => _reconnecting;

  /// Logo saved from an earlier visit, shown until the station sends one.
  Uint8List? get cachedLogo => _cachedLogo;

  /// Logo of a station, live when tuned there, otherwise saved from an
  /// earlier visit. Null until one has been received or loaded.
  Uint8List? stationLogo(int frequencyHz, int program) {
    if (_state.frequencyHz == frequencyHz) {
      final logo = _state.hd.logoFor(program)?.bytes;
      if (logo != null) return logo;
      if (_state.program == program && _cachedLogo != null) return _cachedLogo;
    }
    return _artCache.memory(
          ArtCache.logoKey(frequencyHz: frequencyHz, program: program),
        ) ??
        (program == 0
            ? null
            : _artCache.memory(
                ArtCache.logoKey(frequencyHz: frequencyHz, program: 0),
              ));
  }

  /// [stationLogo], reading a previously saved logo from disk when needed.
  Future<Uint8List?> loadStationLogo(int frequencyHz, int program) async {
    final ready = stationLogo(frequencyHz, program);
    if (ready != null) return ready;
    final own = await _artCache.load(
      ArtCache.logoKey(frequencyHz: frequencyHz, program: program),
    );
    if (own != null) return own;
    if (program == 0) return null;
    return _artCache.load(
      ArtCache.logoKey(frequencyHz: frequencyHz, program: 0),
    );
  }

  int get _defaultFrequency =>
      _settings.slots.whereType<Preset>().firstOrNull?.frequencyHz ??
      band.snap((band.minHz + band.maxHz) ~/ 2);

  // ---------------------------------------------------------------------------
  // Lifecycle / connection
  // ---------------------------------------------------------------------------

  Future<void> start() async {
    _applySettingsToEngine();
    _deviceSub = devices.events.listen(_onDeviceEvent);
    _loadCachedLogo();
    try {
      final launch = await devices.takeLaunchDevice();
      if (launch != null) {
        await connectDevice(launch);
      } else if (_settings.autoConnect) {
        await connectPreferred(quiet: true);
      }
    } on Object catch (e, st) {
      _log.warning('Auto-connect failed', e, st);
    }
  }

  void _applySettingsToEngine() {
    final s = _settings;
    engine
      ..setAudioMode(s.audioMode)
      ..setGain(s.gainMode, gainTenthDb: s.manualGainTenthDb)
      ..setPpm(s.ppm)
      ..setBiasTee(s.biasTee)
      ..setDeemphasisUs(s.band.deemphasisUs)
      ..setBlendAlignmentMs(s.blendAlignmentMs)
      ..setSquelchDb(s.squelchDb)
      ..setVolume(s.volume)
      ..setHdVolume(s.hdVolume)
      ..setProgram(s.lastProgram)
      ..setAudioEnabled(_audioEnabled);
  }

  /// Opens the source chosen in settings (first USB tuner, or rtl_tcp).
  Future<void> connectPreferred({bool quiet = false}) async {
    switch (_settings.sourceKind) {
      case SourceKind.rtlTcp:
        if (quiet) return;
        await connect(
          RtlTcpSource(_settings.rtlTcpHost, port: _settings.rtlTcpPort),
        );
      case SourceKind.usb:
        final list = await devices.listDevices();
        if (list.isEmpty) {
          if (!quiet) _setError('No tuner found');
          return;
        }
        await connectDevice(list.first);
    }
  }

  Future<void> connectDevice(SdrDevice device) async {
    // The engine must stop reading the old USB connection before the
    // platform side replaces it.
    await _closeSource();
    try {
      final source = await devices.open(device);
      if (source == null) {
        _setError('USB permission was not granted.');
        return;
      }
      _deviceHeld = true;
      await connect(source);
    } on Object catch (e) {
      _setError(e is RadioEngineException ? e.message : '$e');
      await _releaseDevice();
    }
  }

  Future<void> connect(SourceConfig source) async {
    _cancelOperations();
    if (source is! UsbFdSource && source is! UsbIndexSource && _deviceHeld) {
      await _closeSource();
    }
    final frequency = switch (source) {
      FileSource(:final frequencyHz) => frequencyHz,
      _ => _settings.lastFrequencyHz ?? _defaultFrequency,
    };
    _state = _state.copyWith(
      phase: ConnectionPhase.connecting,
      sourceLabel: source.label,
      errorMessage: null,
      program: _settings.lastProgram,
    );
    notifyListeners();
    _log.info(
      'Opening ${source.label} at ${frequency == null ? '-' : formatMhz(frequency)} MHz',
    );
    engine.setProgram(_settings.lastProgram);
    try {
      await engine.open(
        source,
        frequencyHz: frequency,
        gainHintTenthDb: frequency == null ? null : _gainHint(frequency),
      );
      if (source is RtlTcpSource) {
        _updateSettings(
          _settings.copyWith(
            sourceKind: SourceKind.rtlTcp,
            rtlTcpHost: source.host,
            rtlTcpPort: source.port,
          ),
        );
      } else if (source is UsbFdSource || source is UsbIndexSource) {
        _updateSettings(_settings.copyWith(sourceKind: SourceKind.usb));
      }
    } on RadioEngineException catch (e) {
      _log.warning('Open failed: ${e.message}');
      _setError(_state.errorMessage ?? e.message);
      await _releaseDevice();
    }
  }

  Future<void> disconnect() async {
    if (_state.phase == ConnectionPhase.streaming ||
        _state.phase == ConnectionPhase.connecting) {
      _log.info('Disconnecting');
    }
    _stopReconnecting();
    _cancelOperations();
    await _closeSource();
  }

  void _stopReconnecting() {
    _reconnectToken++;
    if (_reconnecting) {
      _reconnecting = false;
      notifyListeners();
    }
  }

  /// The desktop has no plug-in notification, so after a USB receiver drops
  /// out (often a hub resetting it), look for it until it is back.
  Future<void> _reconnectWhenBack() async {
    if (devices.hotplug ||
        !_settings.autoConnect ||
        _settings.sourceKind != SourceKind.usb) {
      return;
    }
    final token = ++_reconnectToken;
    _reconnecting = true;
    notifyListeners();
    _log.info('Waiting for the receiver to come back');
    final deadline = DateTime.now().add(_reconnectFor);
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(reconnectInterval);
        if (token != _reconnectToken || _settings.sourceKind != SourceKind.usb) {
          return;
        }
        if (_state.phase == ConnectionPhase.streaming ||
            _state.phase == ConnectionPhase.connecting) {
          return;
        }
        final found = await devices.listDevices();
        if (token != _reconnectToken || found.isEmpty) continue;
        _log.info('Tuner is back: ${found.first.name}');
        await connectDevice(found.first);
        if (_state.phase == ConnectionPhase.streaming) return;
      }
      _log.info('Gave up waiting for the receiver');
    } finally {
      if (token == _reconnectToken && _reconnecting) {
        _reconnecting = false;
        notifyListeners();
      }
    }
  }

  Future<void> _closeSource() async {
    if (_state.phase == ConnectionPhase.streaming ||
        _state.phase == ConnectionPhase.connecting) {
      await engine.close();
    }
    await _releaseDevice();
  }

  /// Releases the platform USB connection if this controller opened one.
  Future<void> _releaseDevice() async {
    if (!_deviceHeld) return;
    _deviceHeld = false;
    await devices.release();
  }

  Future<void> shutdown() async {
    _reconnectToken++;
    _cancelOperations();
    _saveTimer?.cancel();
    await _settingsStore.save(_settings);
    await _deviceSub?.cancel();
    await _engineSub?.cancel();
    _radioDns.close();
    _logoTimer?.cancel();
    await engine.dispose();
  }

  void _setError(String message) {
    _state = _state.copyWith(
      phase: ConnectionPhase.error,
      errorMessage: message,
    );
    notifyListeners();
  }

  void _onDeviceEvent(DeviceEvent event) {
    switch (event) {
      case DeviceAttached(:final device):
        _log.info('USB attached: ${device.name}');
        if (_settings.autoConnect &&
            !_state.isStreaming &&
            _state.phase != ConnectionPhase.connecting) {
          unawaited(connectDevice(device));
        }
      case DeviceDetached(:final device):
        _log.info('USB detached: ${device.name}');
    }
  }

  // ---------------------------------------------------------------------------
  // Tuning
  // ---------------------------------------------------------------------------

  int? _gainHint(int frequencyHz) => _settings.gainMode == GainMode.auto
      ? _settings.gainCache[frequencyHz]
      : null;

  void tune(int frequencyHz, {int program = 0}) {
    _cancelOperations();
    _logoLookupOffline = false;
    _tune(frequencyHz, program: program);
  }

  void _tune(int frequencyHz, {int program = 0}) {
    // FM/HD chips last for one station. The saved mode (Auto prefers HD)
    // applies again on the next tune.
    if (_audioModeHeld) _releaseAudioModeHold();
    if (program != _state.program) {
      engine.setProgram(program);
      _state = _state.copyWith(program: program);
    }
    // Apply locally before the engine echo, so a tune is logged once.
    _state = reduceRadioState(_state, TunedEvent(frequencyHz));
    _logTune(frequencyHz, program);
    engine.tune(frequencyHz, gainHintTenthDb: _gainHint(frequencyHz));
    _updateSettings(
      _settings.copyWith(lastFrequencyHz: frequencyHz, lastProgram: program),
    );
    _loadCachedLogo();
    notifyListeners();
    if (!_scan.active && !_seeking) _scheduleLogoLookup();
  }

  void stepChannel(int direction) =>
      tune(band.step(_state.frequencyHz ?? _defaultFrequency, direction));

  void selectProgram(int program) {
    if (program == _state.program) return;
    engine.setProgram(program);
    _log.info('Program HD${program + 1}');
    _state = _state.copyWith(program: program);
    _updateSettings(_settings.copyWith(lastProgram: program));
    _loadCachedLogo();
    notifyListeners();
  }

  /// Plays analog FM when [hdProgram] is null, otherwise that HD program
  /// (0 = HD1). Analog FM is the station's main channel, so choosing it
  /// selects HD1's program.
  ///
  /// This does not change the saved mode. In Auto, HD stays preferred, and
  /// choosing FM plays analog only until the next tune.
  void selectAudioSource(int? hdProgram) {
    if (hdProgram == null) {
      _audioModeHeld = _settings.audioMode != AudioMode.analog;
      _useAudioMode(AudioMode.analog);
      if (_state.program != 0) {
        selectProgram(0);
      } else {
        notifyListeners();
      }
      return;
    }
    if (_settings.audioMode == AudioMode.analog) {
      // FM only is the saved default; this HD program lasts until the next tune.
      _audioModeHeld = true;
      _useAudioMode(AudioMode.auto);
    } else if (_audioModeHeld) {
      _releaseAudioModeHold();
    }
    if (hdProgram != _state.program) {
      selectProgram(hdProgram);
    } else {
      notifyListeners();
    }
  }

  void _useAudioMode(AudioMode mode) {
    if (_state.audioMode == mode) return;
    engine.setAudioMode(mode);
    _state = _state.copyWith(audioMode: mode);
    _log.info(
      'Audio mode ${mode.name}${_audioModeHeld ? ' until the next tune' : ''}',
    );
  }

  void _releaseAudioModeHold() {
    _audioModeHeld = false;
    _useAudioMode(_settings.audioMode);
  }

  /// Next station up or down in the scanned station list, wrapping around the
  /// band. With no list, and a live receiver, steps until a carrier shows up.
  /// Hold-to-scan is [scanSeek].
  Future<void> seek(int direction) async {
    final generation = _cancelOperations();
    final start = _state.frequencyHz ?? _defaultFrequency;
    _log.info(
      'Seeking ${direction > 0 ? 'up' : 'down'} from ${formatMhz(start)}',
    );
    final known = [
      for (final s in _settings.stations)
        if (band.contains(s.frequencyHz)) s.frequencyHz,
    ]..sort();
    if (known.isNotEmpty) {
      final next = direction > 0
          ? known.firstWhere((f) => f > start, orElse: () => known.first)
          : known.lastWhere((f) => f < start, orElse: () => known.last);
      _logoLookupOffline = false;
      _tune(next);
      return;
    }
    if (!_state.isStreaming) {
      _logoLookupOffline = false;
      _tune(band.step(start, direction));
      return;
    }
    _seeking = true;
    notifyListeners();
    try {
      var f = start;
      for (var i = 0; i < band.channelCount - 1; i++) {
        f = band.step(f, direction);
        _tune(f);
        if (await _probeSignal(generation)) {
          _log.info('Seek stopped at ${formatMhz(f)}');
          return;
        }
        if (generation != _generation) return;
      }
      if (generation == _generation) _log.info('Seek found nothing');
    } finally {
      if (generation == _generation) {
        _seeking = false;
        _logoLookupOffline = false;
        notifyListeners();
        _scheduleLogoLookup();
      }
    }
  }

  /// Tunes through the band for the next station, ignoring the scanned list.
  /// FM stops on a usable carrier. HD only stops once HD locks, and moves
  /// past empty channels without waiting. Output is muted until it stops.
  Future<void> scanSeek(int direction) async {
    final generation = _cancelOperations();
    final start = _state.frequencyHz ?? _defaultFrequency;
    final target = _settings.seekScan;
    _log.info(
      'Scanning ${direction > 0 ? 'up' : 'down'} for ${target.label} from ${formatMhz(start)}',
    );
    if (!_state.isStreaming) {
      _logoLookupOffline = false;
      _tune(band.step(start, direction));
      return;
    }
    _seeking = true;
    _muteWhileSeeking();
    notifyListeners();
    try {
      var f = start;
      for (var i = 0; i < band.channelCount - 1; i++) {
        if (generation != _generation) return;
        f = band.step(f, direction);
        _tune(f);
        if (await _probeSignal(generation, target: target)) {
          _log.info('Scan stopped at ${formatMhz(f)}');
          return;
        }
      }
      if (generation == _generation) _log.info('Scan found nothing');
    } finally {
      if (generation == _generation) {
        _seeking = false;
        _restoreSeekAudio();
        _logoLookupOffline = false;
        notifyListeners();
        _scheduleLogoLookup();
      }
    }
  }

  static const _carrierSettle = Duration(milliseconds: 300);
  static const _carrierListen = Duration(milliseconds: 400);

  /// Extra time on a carrier for NRSC-5 to lock. Empty channels skip this.
  static const _hdPoll = Duration(milliseconds: 200);
  static const _hdPolls = 8;
  static const _stationSnrDb = 12.0;

  /// True when this channel is a stop for [target]. FM is a carrier (or an
  /// HD lock). HD only is an HD lock, after a short wait when a carrier is present.
  Future<bool> _probeSignal(
    int generation, {
    SeekScan target = SeekScan.fm,
  }) async {
    await Future<void>.delayed(_carrierSettle);
    if (generation != _generation) return false;
    if (_state.hd.synced) return true;
    final reports = await _collect<SignalEvent>(_carrierListen);
    if (generation != _generation) return false;
    if (_state.hd.synced) return true;
    final snr = reports.isEmpty
        ? null
        : reports.map((r) => r.snrDb).reduce(math.max);
    if (snr == null || snr < _stationSnrDb) return false;
    if (target == SeekScan.fm) return true;
    for (var i = 0; i < _hdPolls; i++) {
      await Future<void>.delayed(_hdPoll);
      if (generation != _generation) return false;
      if (_state.hd.synced) return true;
    }
    return false;
  }

  /// Sweeps the band with spectrum snapshots, then (optionally) visits each
  /// candidate to learn its name and whether it carries HD.
  Future<void> scanBand({bool identify = true}) async {
    if (!_state.isStreaming || _scan.active) return;
    final generation = _cancelOperations();
    final resumeFrequency = _state.frequencyHz;
    final resumeProgram = _state.program;
    final scanGain = (_state.gain?.converged ?? false)
        ? _state.gain!.gainTenthDb
        : 197;
    final previous = {for (final s in _settings.stations) s.frequencyHz: s};

    engine
      ..setAudioEnabled(false)
      ..setGain(GainMode.manual, gainTenthDb: scanGain);
    acquireSpectrum();
    _scan = const ScanStatus(phase: ScanPhase.sweeping);
    _log.info('Band scan started');
    notifyListeners();

    var completed = false;
    String? failure;
    _scanStopped = false;
    try {
      final centers = scanCenters(band);
      final channels = <ChannelPower>[];
      var measured = 0;
      for (var i = 0; i < centers.length; i++) {
        final center = centers[i];
        engine.tune(center);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final spectra = await _collect<SpectrumEvent>(
          const Duration(milliseconds: 400),
          where: (s) => s.centerHz == center,
        );
        if (generation != _generation) return;
        if (spectra.isNotEmpty) {
          measured++;
          channels.addAll(
            measureChannels(
              band: band,
              centerHz: center,
              spanHz: spectra.first.spanHz,
              binsDb: _average(spectra),
            ),
          );
        }
        _scan = ScanStatus(
          phase: ScanPhase.sweeping,
          progress: (i + 1) / centers.length,
        );
        notifyListeners();
      }
      // A receiver that stops sending samples without disconnecting leaves
      // gaps in the sweep. A list built from them would drop real stations.
      if (measured < centers.length * 0.8) {
        _log.warning(
          'Band scan measured $measured of ${centers.length} segments; keeping the old list',
        );
        failure = measured == 0
            ? 'The receiver sent no data, so the scan stopped.'
            : 'The receiver stopped responding partway through the scan.';
        return;
      }

      final found = [
        for (final c in pickStations(channels))
          (previous[c.frequencyHz] ?? KnownStation(frequencyHz: c.frequencyHz))
              .copyWith(snrDb: c.snrDb),
      ];
      _log.info('Scan found ${found.length} stations');
      engine
        ..setGain(_settings.gainMode, gainTenthDb: _settings.manualGainTenthDb)
        ..setAudioEnabled(false);

      if (identify) {
        _logoLookupOffline = false;
        if (_settings.downloadLogos) _radioDns.beginPass();
        for (var i = 0; i < found.length; i++) {
          _scan = ScanStatus(
            phase: ScanPhase.identifying,
            progress: i / found.length,
            found: List.of(found),
          );
          notifyListeners();
          _tune(found[i].frequencyHz);
          final info = await _identify(generation);
          if (generation != _generation) return;
          found[i] = found[i].copyWith(
            name: info.name,
            hd: info.hd,
            programs: info.programs,
            category: info.category,
          );
          await _downloadLogoForTunedStation(generation);
          if (generation != _generation) return;
        }
      }
      _updateSettings(_settings.copyWith(stations: found));
      completed = true;
    } finally {
      releaseSpectrum();
      engine
        ..setGain(_settings.gainMode, gainTenthDb: _settings.manualGainTenthDb)
        ..setAudioEnabled(_audioEnabled);
      if (!completed && !_state.isStreaming) {
        failure = 'The receiver was lost during the scan.';
        _log.warning('Band scan stopped: receiver lost');
      }
      // Back to where the scan started, unless the user tuned somewhere else.
      final resume = completed || failure != null || _scanStopped;
      if (resume && _state.isStreaming && resumeFrequency != null) {
        _tune(resumeFrequency, program: resumeProgram);
      }
      _scan = ScanStatus(
        error: failure == null
            ? null
            : '$failure Your station list was not changed.',
      );
      if (completed) _scheduleLogoLookup();
      notifyListeners();
    }
  }

  Future<({String? name, bool hd, int programs, String? category})> _identify(
    int generation,
  ) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(milliseconds: 3500)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (generation != _generation) break;
      final s = _state;
      final ms = watch.elapsedMilliseconds;
      final logoReady =
          !_settings.downloadLogos ||
          s.hd.logoFor(0) != null ||
          s.fm.rds.pi != null ||
          (s.hd.facilityId ?? 0) > 0;
      if (s.hd.name != null &&
          s.hd.programs.isNotEmpty &&
          (logoReady || ms > 3000)) {
        break;
      }
      if (!s.hd.synced &&
          s.fm.rds.psTrimmed != null &&
          ms > 1500 &&
          (logoReady || ms > 3000)) {
        break;
      }
      if (!s.hd.synced && !(s.fm.status?.rdsSynced ?? false) && ms > 2000) {
        break;
      }
    }
    final s = _state;
    return (
      name: s.stationName,
      hd: s.hd.isHdStation,
      programs: math.max(1, s.hd.programs.length),
      category: programCategory(s, band),
    );
  }

  void cancelScan() {
    _scanStopped = true;
    _cancelOperations();
  }

  Float32List _average(List<SpectrumEvent> spectra) {
    final out = Float32List(spectra.first.binsDb.length);
    for (final s in spectra) {
      for (var i = 0; i < out.length && i < s.binsDb.length; i++) {
        out[i] += s.binsDb[i] / spectra.length;
      }
    }
    return out;
  }

  void _muteWhileSeeking() {
    if (_seekMuted) return;
    _seekMuted = true;
    engine.setAudioEnabled(false);
  }

  void _restoreSeekAudio() {
    if (!_seekMuted) return;
    _seekMuted = false;
    engine.setAudioEnabled(_audioEnabled);
  }

  /// Bumps the operation generation so running seek/scan loops stop.
  int _cancelOperations() {
    _seeking = false;
    _restoreSeekAudio();
    _logoTimer?.cancel();
    return ++_generation;
  }

  Future<List<T>> _collect<T extends RadioEvent>(
    Duration window, {
    bool Function(T)? where,
  }) async {
    final out = <T>[];
    final sub = engine.events.listen((e) {
      if (e is T && (where == null || where(e))) out.add(e);
    });
    await Future<void>.delayed(window);
    await sub.cancel();
    return out;
  }

  // ---------------------------------------------------------------------------
  // Audio / receiver settings
  // ---------------------------------------------------------------------------

  void setAudioEnabled(bool enabled) {
    if (_audioEnabled != enabled) _log.info(enabled ? 'Audio on' : 'Muted');
    _audioEnabled = enabled;
    engine.setAudioEnabled(enabled);
    notifyListeners();
  }

  void setVolume(double volume) {
    engine.setVolume(_ducked ? volume * _duckFactor : volume);
    _updateSettings(_settings.copyWith(volume: volume));
    notifyListeners();
  }

  /// HD level relative to analog FM. 1 matches FM.
  void setHdVolume(double level) {
    final clamped = clampHdVolume(level);
    engine.setHdVolume(clamped);
    _updateSettings(_settings.copyWith(hdVolume: clamped));
    notifyListeners();
  }

  static const _duckFactor = 0.25;
  bool _ducked = false;

  /// Temporarily lowers the output (another app's navigation prompt etc.).
  void duck(bool ducked) {
    _ducked = ducked;
    engine.setVolume(
      ducked ? _settings.volume * _duckFactor : _settings.volume,
    );
  }

  void setAudioMode(AudioMode mode) {
    _audioModeHeld = false;
    _useAudioMode(mode);
    _updateSettings(_settings.copyWith(audioMode: mode));
    notifyListeners();
  }

  void setGain(GainMode mode, {int? manualTenthDb}) {
    final manual = manualTenthDb ?? _settings.manualGainTenthDb;
    if (mode != _settings.gainMode || manual != _settings.manualGainTenthDb) {
      _log.fine(
        'Gain ${mode.name}${mode == GainMode.manual ? ' ${(manual / 10).toStringAsFixed(1)} dB' : ''}',
      );
    }
    engine.setGain(mode, gainTenthDb: manual);
    _updateSettings(
      _settings.copyWith(gainMode: mode, manualGainTenthDb: manual),
    );
    notifyListeners();
  }

  void setBand(BandPlan plan) {
    engine.setDeemphasisUs(plan.deemphasisUs);
    _updateSettings(_settings.copyWith(band: plan));
    final f = _state.frequencyHz;
    if (f != null && !plan.contains(f)) tune(plan.snap(f));
    notifyListeners();
  }

  void setPpm(int ppm) {
    engine.setPpm(ppm);
    _updateSettings(_settings.copyWith(ppm: ppm));
    notifyListeners();
  }

  void setBiasTee(bool enabled) {
    engine.setBiasTee(enabled);
    _updateSettings(_settings.copyWith(biasTee: enabled));
    notifyListeners();
  }

  void setBlendAlignmentMs(int milliseconds) {
    engine.setBlendAlignmentMs(milliseconds);
    _updateSettings(_settings.copyWith(blendAlignmentMs: milliseconds));
    notifyListeners();
  }

  /// Analog FM mute level in dB CNR. Negative turns squelch off.
  void setSquelchDb(int thresholdDb) {
    final db = clampSquelchDb(thresholdDb);
    if (db != _settings.squelchDb) {
      _log.fine(db < 0 ? 'Squelch off' : 'Squelch threshold $db dB');
    }
    engine.setSquelchDb(db);
    _updateSettings(_settings.copyWith(squelchDb: db));
    notifyListeners();
  }

  void setAutoConnect(bool enabled) {
    _updateSettings(_settings.copyWith(autoConnect: enabled));
    notifyListeners();
  }

  void setDownloadLogos(bool enabled) {
    _updateSettings(_settings.copyWith(downloadLogos: enabled));
    notifyListeners();
  }

  void setSeekScan(SeekScan scan) {
    if (scan == _settings.seekScan) return;
    _updateSettings(_settings.copyWith(seekScan: scan));
    notifyListeners();
  }

  void setMediaKeys(MediaKeys keys) {
    if (keys == _settings.mediaKeys) return;
    _updateSettings(_settings.copyWith(mediaKeys: keys));
    notifyListeners();
  }

  /// Next or previous for the lock screen, notification, and media keys.
  Future<void> mediaKey(int direction) {
    switch (_settings.mediaKeys) {
      case MediaKeys.presets:
        _tunePreset(direction);
        return Future<void>.value();
      case MediaKeys.scan:
        return scanSeek(direction);
      case MediaKeys.step:
        stepChannel(direction);
        return Future<void>.value();
    }
  }

  /// Next or previous saved preset, skipping empty slots and wrapping.
  /// With nothing saved, stays put. Off a preset, up starts at the first
  /// saved slot and down at the last.
  void _tunePreset(int direction) {
    final slots = _settings.slots;
    final filled = [
      for (var i = 0; i < slots.length; i++)
        if (slots[i] != null) i,
    ];
    if (filled.isEmpty) {
      _log.fine('No presets');
      return;
    }
    final f = _state.frequencyHz;
    final onPreset = f == null
        ? -1
        : filled.indexWhere((i) => slots[i]!.matches(f, _state.program));
    final int index;
    if (onPreset < 0) {
      index = direction < 0 ? filled.last : filled.first;
    } else {
      final step = direction < 0 ? -1 : 1;
      final wrapped = (onPreset + step) % filled.length;
      index = filled[wrapped < 0 ? wrapped + filled.length : wrapped];
    }
    final preset = slots[index]!;
    _log.info('Preset ${index + 1}');
    tune(preset.frequencyHz, program: preset.program);
  }

  /// RadioDNS logo for the tuned station, when the setting is on, the station
  /// has no broadcast logo, and the network answers. A tune or seek waits
  /// briefly so a broadcast logo can arrive first; a band scan calls this
  /// after it has already identified the station.
  @visibleForTesting
  Future<void> downloadLogoForTunedStation() =>
      _downloadLogoForTunedStation(_generation);

  /// Gives the station a moment to send its own logo, then looks one up.
  void _scheduleLogoLookup() {
    _logoTimer?.cancel();
    if (!_settings.downloadLogos ||
        _logoLookupOffline ||
        _scan.active ||
        _seeking) {
      return;
    }
    final generation = _generation;
    _logoTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_downloadLogoForTunedStation(generation));
    });
  }

  Future<void> _downloadLogoForTunedStation(int generation) async {
    if (!_settings.downloadLogos || _logoLookupOffline) return;
    final f = _state.frequencyHz;
    if (f == null || generation != _generation) return;
    if (_state.hd.logoFor(0) != null) return;
    final key = ArtCache.logoKey(frequencyHz: f, program: 0);
    if (await _artCache.load(key) != null) return;
    if (generation != _generation) return;
    final queries = RadioDns.queries(
      frequencyHz: f,
      band: band,
      pi: _state.fm.rds.pi ?? piFromStationText(_state.stationName),
      facilityId: _state.hd.facilityId,
      countryCode: _state.hd.countryCode,
    );
    if (queries.isEmpty) {
      _log.fine('No RadioDNS id for ${formatMhz(f)}');
      return;
    }
    try {
      final bytes = await _radioDns.logo(queries);
      if (bytes == null) {
        _log.fine('No RadioDNS logo for ${formatMhz(f)}');
        return;
      }
      await _artCache.store(key, bytes);
      _log.info('RadioDNS logo for ${formatMhz(f)} (${bytes.length} bytes)');
      if (_state.frequencyHz == f) {
        _cachedLogo = bytes;
        notifyListeners();
      }
    } on RadioDnsOffline {
      _logoLookupOffline = true;
      _log.info('Logo lookup skipped: no internet');
    }
  }

  void setRtlTcp(String host, int port) {
    _updateSettings(
      _settings.copyWith(
        rtlTcpHost: host,
        rtlTcpPort: port,
        sourceKind: SourceKind.rtlTcp,
      ),
    );
    notifyListeners();
  }

  void setSourceKind(SourceKind kind) {
    _updateSettings(_settings.copyWith(sourceKind: kind));
    notifyListeners();
  }

  /// Null picks a size for the screen.
  void setUiScale(double? scale) {
    _updateSettings(_settings.copyWith(uiScale: scale));
    notifyListeners();
  }

  void setTheme(AppTheme theme) {
    _updateSettings(_settings.copyWith(theme: theme));
    notifyListeners();
  }

  /// 1 fills the space above the presets.
  void setStationScale(double scale) {
    _updateSettings(_settings.copyWith(stationScale: clampStationScale(scale)));
    notifyListeners();
  }

  /// Preset row size. 1 is sized for a finger.
  void setPresetScale(double scale) {
    _updateSettings(_settings.copyWith(presetScale: clampPresetScale(scale)));
    notifyListeners();
  }

  /// How many preset slots are shown. Shrinking hides the tail; growing
  /// shows it again. A bank smaller than one page shortens the page.
  void setPresetCount(int count) {
    final n = clampPresetCount(count);
    var per = _settings.presetsPerPage;
    if (per > n) per = clampPresetsPerPage(n);
    _updateSettings(_settings.copyWith(presetCount: n, presetsPerPage: per));
    notifyListeners();
  }

  /// Slots on one carousel page. Growing past the bank adds slots so the
  /// page can fill.
  void setPresetsPerPage(int perPage) {
    final per = clampPresetsPerPage(perPage);
    var n = _settings.presetCount;
    if (n < per) n = clampPresetCount(per);
    _updateSettings(_settings.copyWith(presetCount: n, presetsPerPage: per));
    notifyListeners();
  }

  void setPresetSide(PresetSide side) {
    _updateSettings(_settings.copyWith(presetSide: side));
    notifyListeners();
  }

  void setPresetArrows(PresetArrows mode) {
    _updateSettings(_settings.copyWith(presetArrows: mode));
    notifyListeners();
  }

  void setLogLevel(LogDetail level) {
    _updateSettings(_settings.copyWith(logLevel: level));
    _logs?.setLevel(levelFor(level));
    notifyListeners();
  }

  /// Spectrum events are only produced while someone is looking.
  void acquireSpectrum() {
    if (_spectrumUsers++ == 0) engine.setSpectrumEnabled(true);
  }

  void releaseSpectrum() {
    if (_spectrumUsers == 0) return;
    if (--_spectrumUsers == 0) engine.setSpectrumEnabled(false);
  }

  // ---------------------------------------------------------------------------
  // Presets / stations
  // ---------------------------------------------------------------------------

  bool get isCurrentPreset {
    final f = _state.frequencyHz;
    return f != null &&
        _settings.slots.any((p) => p?.matches(f, _state.program) ?? false);
  }

  /// Saves the tuned station into [index], replacing whatever was there.
  ///
  /// Returns the 1-based number of the slot that already has this frequency
  /// and HD program, and leaves the bank unchanged. The same slot can be
  /// saved again. A different HD program of the same station is its own preset.
  int? storePreset(int index) {
    final f = _state.frequencyHz;
    if (f == null || index < 0 || index >= _settings.presetCount) return null;
    final presets = [..._settings.slots];
    final duplicate = presets.indexWhere(
      (p) => p?.matches(f, _state.program) ?? false,
    );
    if (duplicate >= 0 && duplicate != index) return duplicate + 1;
    presets[index] = Preset(
      frequencyHz: f,
      program: _state.program,
      name: _state.stationName,
    );
    _writeSlots(presets);
    notifyListeners();
    return null;
  }

  void clearPreset(int index) {
    if (index < 0 || index >= _settings.presetCount) return;
    final presets = [..._settings.slots];
    if (presets[index] == null) return;
    presets[index] = null;
    _writeSlots(presets);
    notifyListeners();
  }

  void renamePreset(Preset preset, String? name) {
    final presets = [
      for (final p in _settings.slots)
        identical(p, preset)
            ? p!.withName(name?.trim().isEmpty ?? true ? null : name!.trim())
            : p,
    ];
    _writeSlots(presets);
    notifyListeners();
  }

  /// [newIndex] is the position after [oldIndex] has been removed.
  void reorderPresets(int oldIndex, int newIndex) {
    final presets = [..._settings.slots];
    if (oldIndex < 0 || oldIndex >= presets.length) return;
    final p = presets.removeAt(oldIndex);
    presets.insert(newIndex.clamp(0, presets.length), p);
    _writeSlots(presets);
    notifyListeners();
  }

  /// Writes the visible slots and keeps any presets hidden by a smaller bank.
  void _writeSlots(List<Preset?> visible) {
    final stored = _settings.presets;
    final next = stored.length > visible.length
        ? [...visible, ...stored.sublist(visible.length)]
        : visible;
    _updateSettings(_settings.copyWith(presets: next));
  }

  void clearStations() {
    _updateSettings(_settings.copyWith(stations: const []));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Logging
  // ---------------------------------------------------------------------------

  bool get _quietLog => _seeking || _scan.active;

  /// Time source for log pacing; replaced in tests.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// What has already been reported at INFO on this station.
  final _announced = <String>{};

  /// RDS text arrives a few characters at a time; it is reported once it has
  /// stopped changing.
  static const _radioTextSettle = Duration(milliseconds: 2500);
  String? _radioTextPending;
  DateTime? _radioTextSince;
  String? _radioTextLogged;

  /// INFO the first time something happens on this station, FINE after. A
  /// weak signal flips HD lock, squelch, and the audio source many times a
  /// minute, and only the first of each is news.
  void _once(String key, String message) {
    if (!_quietLog && _announced.add(key)) {
      _log.info(message);
    } else {
      _log.fine(message);
    }
  }

  void _logTune(int frequencyHz, int program) {
    _announced.clear();
    _radioTextPending = _radioTextSince = _radioTextLogged = null;
    final line =
        'Tuned ${formatMhz(frequencyHz)} MHz${program > 0 ? ' HD${program + 1}' : ''}';
    if (_quietLog) {
      _log.fine(line);
    } else {
      _log.info(line);
    }
  }

  /// What changed because of one engine event. Meters are ignored; squelch,
  /// stereo and the audio source are reported only when they change.
  void _logChanges(RadioState before) {
    final after = _state;
    if (before.frequencyHz != after.frequencyHz && after.frequencyHz != null) {
      _logTune(after.frequencyHz!, after.program);
    }
    if (before.device != after.device && after.device != null) {
      _log.info('${after.device!.description}, tuner ${after.device!.tuner}');
    }
    _logHd(
      before.hd,
      after.hd,
      retuned: before.frequencyHz != after.frequencyHz,
    );
    _logFm(before.fm, after.fm);
    _logAudio(before.audio, after.audio);
    _logGain(before.gain, after.gain);
  }

  void _logHd(HdState before, HdState after, {required bool retuned}) {
    // "HD locked" is logged from the event, which carries the frequency offset.
    if (!retuned && before.synced && !after.synced) _once('hd lost', 'HD lost');
    if (after.name != null && after.name != before.name) {
      _log.info('Station ${after.name}');
    }
    if (after.slogan != null && after.slogan != before.slogan) {
      _log.fine('Slogan: ${after.slogan}');
    }
    if (after.message != null && after.message != before.message) {
      _log.fine('Message: ${after.message}');
    }
    if (after.alert != null && after.alert != before.alert) {
      _log.warning('Alert: ${after.alert}');
    }
    if (after.facilityId != null && after.facilityId != before.facilityId) {
      _log.fine('FCC facility ${after.facilityId}');
    }
    for (final entry in after.programs.entries) {
      final old = before.programs[entry.key];
      final info = entry.value;
      if (old != null &&
          old.typeName == info.typeName &&
          old.programType == info.programType) {
        continue;
      }
      final type = info.programType > 0 && info.typeName != null
          ? ' ${info.typeName}'
          : '';
      _log.info('${info.label}$type');
    }
    if (_quietLog) return;
    for (final entry in after.nowPlaying.entries) {
      final track = entry.value;
      final old = before.nowPlaying[entry.key];
      if (old != null && old.sameTrack(track)) continue;
      final line = [
        track.title,
        track.artist,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' — ');
      if (line.isEmpty) continue;
      _log.info('HD${entry.key + 1} playing $line');
    }
    for (final entry in after.logos.entries) {
      final old = before.logos[entry.key];
      if (old != null && old.lotId == entry.value.lotId) continue;
      _log.fine(
        'Logo for ${entry.key < 0 ? 'the station' : 'HD${entry.key + 1}'}',
      );
    }
  }

  void _logFm(FmState before, FmState after) {
    final fm = after.status;
    final prev = before.status;
    if (fm != null && (prev == null || prev.squelched != fm.squelched)) {
      final cnr = fm.cnrDb.toStringAsFixed(1);
      fm.squelched
          ? _once('squelch closed', 'Squelch closed ($cnr dB CNR)')
          : _once('squelch open', 'Squelch open ($cnr dB CNR)');
    }
    if (!_quietLog && fm != null && fm.stereo && prev?.stereo != true) {
      _log.fine('Stereo');
    }
    if (!_quietLog && fm != null && prev?.stereo == true && !fm.stereo) {
      _log.fine('Mono');
    }
    if (!_quietLog && fm != null && fm.rdsSynced && prev?.rdsSynced != true) {
      _log.fine('RDS sync');
    }
    if (!_quietLog && prev?.rdsSynced == true && fm?.rdsSynced == false) {
      _log.fine('RDS lost');
    }

    final rds = after.rds;
    final old = before.rds;
    if (rds.pi != old.pi && rds.pi != null) {
      final call = rds.callSign;
      final hex = rds.pi!.toRadixString(16).padLeft(4, '0').toUpperCase();
      _log.fine('RDS PI 0x$hex${call == null ? '' : ' $call'}');
    }
    if (rds.pty != old.pty && rds.pty != null) {
      _log.fine('RDS PTY ${rdsProgramTypeName(rds.pty!, band) ?? rds.pty}');
    }
    // PS often scrolls, and RT fills in a few characters at a time: every
    // change is trace detail.
    if (rds.psTrimmed != null && rds.psTrimmed != old.psTrimmed) {
      _log.finest('RDS PS ${rds.psTrimmed}');
    }
    final text = rds.radioText?.trim();
    final now = clock();
    if (text != null && text.isNotEmpty && text != old.radioText?.trim()) {
      _log.finest('RDS text so far: $text');
      _radioTextPending = text;
      _radioTextSince = now;
    }
    final pending = _radioTextPending;
    final since = _radioTextSince;
    if (pending != null &&
        since != null &&
        now.difference(since) >= _radioTextSettle) {
      _radioTextPending = _radioTextSince = null;
      if (pending != _radioTextLogged) {
        _radioTextLogged = pending;
        _quietLog
            ? _log.fine('RDS text: $pending')
            : _log.info('RDS text: $pending');
      }
    }
  }

  void _logAudio(AudioStatusEvent? before, AudioStatusEvent? after) {
    if (after == null) return;
    if (before?.active != after.active) {
      _once('playing ${after.active.name}', 'Playing ${after.active.name}');
    }
    if (!_quietLog &&
        before != null &&
        before.hdAvailable != after.hdAvailable) {
      _log.fine(
        after.hdAvailable ? 'HD audio available' : 'HD audio unavailable',
      );
    }
    if (before != null && after.underruns > before.underruns) {
      _log.warning('Audio underrun (${after.underruns})');
    }
    if (before?.deviceRunning == true && !after.deviceRunning) {
      _log.warning('Audio device stopped');
    }
  }

  void _logGain(GainEvent? before, GainEvent? after) {
    if (_quietLog || after == null) return;
    if (before != null &&
        before.mode == after.mode &&
        before.gainTenthDb == after.gainTenthDb &&
        before.converged == after.converged) {
      return;
    }
    final db = (after.gainTenthDb / 10).toStringAsFixed(1);
    final settled = after.converged ? ', settled' : '';
    if (before == null ||
        before.mode != after.mode ||
        before.gainTenthDb != after.gainTenthDb) {
      _log.fine('Gain $db dB ${after.mode.name}$settled');
    } else if (after.converged) {
      _log.fine('Gain settled at $db dB');
    }
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onEvent(RadioEvent e) {
    if (e is LogEvent) {
      final level = switch (e.level) {
        EngineLogLevel.debug => Level.FINE,
        EngineLogLevel.info => Level.INFO,
        EngineLogLevel.warn => Level.WARNING,
        EngineLogLevel.error => Level.SEVERE,
      };
      _nativeLog.log(level, '[${e.tag}] ${e.message}');
      return;
    }
    final before = _state;
    _state = reduceRadioState(_state, e);

    switch (e) {
      case SourceStateEvent(:final state, :final message):
        _log.info('Source ${state.name}${message == null ? '' : ': $message'}');
        if (state == SourceState.lost || state == SourceState.error) {
          _cancelOperations();
          unawaited(_releaseDevice());
          if (state == SourceState.lost && !_reconnecting) {
            unawaited(_reconnectWhenBack());
          }
        } else if (state == SourceState.streaming &&
            before.phase != ConnectionPhase.streaming) {
          _logoLookupOffline = false;
          _scheduleLogoLookup();
        }
      case GainEvent(mode: GainMode.auto, converged: true, :final gainTenthDb):
        final f = _state.frequencyHz;
        if (f != null &&
            !_scan.active &&
            _settings.gainCache[f] != gainTenthDb) {
          _updateSettings(
            _settings.copyWith(
              gainCache: {..._settings.gainCache, f: gainTenthDb},
            ),
          );
        }
      case HdLotEvent(
        role: LotRole.stationLogo,
        isImage: true,
        :final data,
        :final program,
      ):
        _logoTimer?.cancel();
        final f = _state.frequencyHz;
        if (f != null) {
          final key = ArtCache.logoKey(
            frequencyHz: f,
            program: math.max(0, program),
          );
          unawaited(_artCache.store(key, data));
        }
      case HdSyncEvent(:final synced, :final freqOffsetHz)
          when synced && !before.hd.synced:
        _once('hd locked', 'HD locked (${freqOffsetHz.round()} Hz)');
      case HdStationIdEvent(:final facilityId)
          when facilityId > 0 && facilityId != before.hd.facilityId:
        _scheduleLogoLookup();
      case HdStationTextEvent(kind: HdStationText.name):
      case RdsEvent():
        if (e is RdsEvent && e.pi != null && e.pi != before.fm.rds.pi) {
          _scheduleLogoLookup();
        }
        _learnStationName();
      case HdLotEvent(
            isImage: true,
            role: LotRole.primaryImage,
            :final program,
            :final data,
          )
          when !_quietLog:
        _log.fine(
          'Album art for HD${math.max(0, program) + 1} (${data.length} bytes)',
        );
      default:
        break;
    }
    _logChanges(before);
    if (!identical(before, _state)) notifyListeners();
  }

  void _learnStationName() {
    final f = _state.frequencyHz;
    if (f == null || _scan.active) return;
    final name = _state.stationName;
    final category = programCategory(_state, band);
    if (name == null && category == null) return;
    final stations = _settings.stations;
    final index = stations.indexWhere((s) => s.frequencyHz == f);
    if (index < 0) return;
    final current = stations[index];
    final nextName = name ?? current.name;
    final nextCategory = category ?? current.category;
    final hd = _state.hd.isHdStation;
    if (current.name == nextName &&
        current.category == nextCategory &&
        current.hd == hd) {
      return;
    }
    final updated = [...stations]
      ..[index] = current.copyWith(
        name: nextName,
        hd: hd,
        category: nextCategory,
      );
    _updateSettings(_settings.copyWith(stations: updated));
  }

  void _loadCachedLogo() {
    final f = _state.frequencyHz;
    _cachedLogo = null;
    if (f == null) return;
    final key = ArtCache.logoKey(frequencyHz: f, program: _state.program);
    final program = _state.program;
    unawaited(
      _artCache.load(key).then((bytes) {
        if (bytes != null &&
            _state.frequencyHz == f &&
            _state.program == program) {
          _cachedLogo = bytes;
          notifyListeners();
        }
      }),
    );
  }

  void _updateSettings(RadioSettings next) {
    _settings = next;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_settingsStore.save(_settings)),
    );
  }
}
