import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../engine/radio_engine.dart';
import '../engine/radio_event.dart';
import '../engine/radio_types.dart';
import '../engine/source_config.dart';
import 'terra_bindings.g.dart';

/// [RadioEngine] backed by libterra_core through `@Native` bindings.
///
/// Native events are queued inside terra_core. This isolate polls them; the
/// DSP thread never calls into the Dart VM, so a hot restart can tear the
/// isolate down while the engine is still streaming. [releaseOrphans] stops
/// engines whose port has closed.
final class NativeRadioEngine implements RadioEngine {
  NativeRadioEngine() {
    _port.listen(_onMessage);
    _engine = terra_engine_create_for_port(NativeApi.postCObject.cast(), _port.sendPort.nativePort);
    if (_engine == nullptr) {
      _port.close();
      throw const RadioEngineException('terra_engine_create failed');
    }
    _pump = Timer.periodic(const Duration(milliseconds: 16), (_) => _drain());
  }

  final _port = ReceivePort('terra events');
  late final Pointer<terra_engine> _engine;
  Timer? _pump;
  final _events = StreamController<RadioEvent>.broadcast(sync: true);
  bool _disposed = false;

  static int get apiVersion => terra_api_version();

  /// Stops engines whose isolate has ended (a hot restart) so this one can
  /// open the receiver they still hold. Returns how many were stopped.
  static Future<int> releaseOrphans() => Isolate.run(terra_engine_destroy_orphans);

  @override
  Stream<RadioEvent> get events => _events.stream;

  @override
  String get version => _string(terra_version_string()) ?? '?';

  @override
  Future<void> open(SourceConfig source, {int? frequencyHz, int? gainHintTenthDb}) async {
    _checkAlive();
    if (frequencyHz != null) terra_engine_tune(_engine, frequencyHz, gainHintTenthDb ?? -1);
    final config = calloc<terra_source_config>();
    final strings = <Pointer<Utf8>>[];
    Pointer<Char> str(String s) {
      final p = s.toNativeUtf8(allocator: calloc);
      strings.add(p);
      return p.cast();
    }

    final ref = config.ref;
    switch (source) {
      case UsbFdSource(:final fd):
        ref.kind = terra_source_kind.TERRA_SOURCE_RTLSDR_FD;
        ref.fd = fd;
      case UsbIndexSource(:final index):
        ref.kind = terra_source_kind.TERRA_SOURCE_RTLSDR_INDEX;
        ref.device_index = index;
      case RtlTcpSource(:final host, :final port):
        ref.kind = terra_source_kind.TERRA_SOURCE_RTL_TCP;
        ref.host = str(host);
        ref.port = port;
      case FileSource(:final path, :final realtime, :final loop):
        ref.kind = terra_source_kind.TERRA_SOURCE_FILE;
        ref.path = str(path);
        ref.realtime = realtime ? 1 : 0;
        ref.loop = loop ? 1 : 0;
    }
    try {
      // Opening USB or connecting to rtl_tcp can block for seconds.
      final rc = await _openOffThread(_engine.address, config.address);
      if (rc != 0) throw RadioEngineException('Could not open ${source.label}', code: rc);
    } finally {
      for (final p in strings) {
        calloc.free(p);
      }
      calloc.free(config);
    }
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    await _closeOffThread(_engine.address);
  }

  // Static so the closures sent to the helper isolate capture only integers.
  static Future<int> _openOffThread(int engine, int config) =>
      Isolate.run(() => terra_engine_open(Pointer.fromAddress(engine), Pointer.fromAddress(config)));

  static Future<void> _closeOffThread(int engine) =>
      Isolate.run(() => terra_engine_close(Pointer.fromAddress(engine)));

  static Future<void> _destroyOffThread(int engine) =>
      Isolate.run(() => terra_engine_destroy(Pointer.fromAddress(engine)));

  @override
  void tune(int frequencyHz, {int? gainHintTenthDb}) {
    _checkAlive();
    terra_engine_tune(_engine, frequencyHz, gainHintTenthDb ?? -1);
  }

  @override
  void setProgram(int program) => _alive(() => terra_engine_set_program(_engine, program));

  @override
  void setAudioMode(AudioMode mode) => _alive(() => terra_engine_set_audio_mode(_engine, mode.code));

  @override
  void setGain(GainMode mode, {int gainTenthDb = 0}) =>
      _alive(() => terra_engine_set_gain(_engine, mode.code, gainTenthDb));

  @override
  void setPpm(int ppm) => _alive(() => terra_engine_set_ppm(_engine, ppm));

  @override
  void setBiasTee(bool enabled) => _alive(() => terra_engine_set_bias_tee(_engine, enabled ? 1 : 0));

  @override
  void setDeemphasisUs(int microseconds) => _alive(() => terra_engine_set_deemphasis_us(_engine, microseconds));

  @override
  void setBlendAlignmentMs(int milliseconds) =>
      _alive(() => terra_engine_set_blend_alignment_ms(_engine, milliseconds));

  @override
  void setSquelchDb(int thresholdDb) => _alive(() => terra_engine_set_squelch_db(_engine, thresholdDb));

  @override
  void setVolume(double volume) => _alive(() => terra_engine_set_volume(_engine, volume));

  @override
  void setHdVolume(double level) => _alive(() => terra_engine_set_hd_level(_engine, level));

  @override
  void setAudioEnabled(bool enabled) => _alive(() => terra_engine_set_audio_enabled(_engine, enabled ? 1 : 0));

  @override
  void setSpectrumEnabled(bool enabled) =>
      _alive(() => terra_engine_set_spectrum_enabled(_engine, enabled ? 1 : 0));

  @override
  List<String> listUsbDevices() {
    final count = terra_rtlsdr_device_count();
    if (count <= 0) return const [];
    const size = 256;
    final buffer = calloc<Char>(size);
    try {
      return [
        for (var i = 0; i < count; i++)
          terra_rtlsdr_device_name(i, buffer, size) == 0 ? _string(buffer) ?? 'Tuner #$i' : 'Tuner #$i',
      ];
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pump?.cancel();
    _drain();
    await _destroyOffThread(_engine.address);
    // Events posted just before destroy may still be queued for this isolate;
    // let them drain (and be freed) before closing the port.
    Timer(const Duration(milliseconds: 500), () {
      _port.close();
      _events.close();
    });
  }

  void _checkAlive() {
    if (_disposed) throw StateError('NativeRadioEngine used after dispose()');
  }

  void _alive(void Function() call) {
    _checkAlive();
    call();
  }

  void _drain() {
    if (_disposed) return;
    while (true) {
      final addr = terra_engine_poll_event(_engine);
      if (addr == 0) return;
      _onNativeEvent(Pointer.fromAddress(addr));
    }
  }

  void _onMessage(Object? message) {
    // Null is terra_engine_destroy_orphans checking that the port is open.
    // Events themselves are pulled by [_drain], not posted onto this port.
    if (message is int) _onNativeEvent(Pointer.fromAddress(message));
  }

  void _onNativeEvent(Pointer<terra_event> event) {
    try {
      final decoded = decodeEvent(event.ref);
      if (decoded != null && !_events.isClosed) _events.add(decoded);
    } finally {
      terra_event_free(event);
    }
  }
}

/// Copies a native event into Dart objects. Returns null for unknown types.
RadioEvent? decodeEvent(terra_event e) {
  final u = e.u;
  switch (e.type) {
    case terra_event_type.TERRA_EVENT_LOG:
      final p = u.log;
      return LogEvent(EngineLogLevel.fromCode(p.level), _string(p.tag) ?? '', _string(p.message) ?? '');
    case terra_event_type.TERRA_EVENT_SOURCE_STATE:
      final p = u.source_state;
      final message = _string(p.message);
      return SourceStateEvent(
        SourceState.fromCode(p.state),
        errorCode: p.error_code,
        message: message == null || message.isEmpty ? null : message,
      );
    case terra_event_type.TERRA_EVENT_DEVICE_INFO:
      final p = u.device_info;
      return DeviceInfoEvent(
        description: _string(p.description) ?? '',
        tuner: _string(p.tuner) ?? '',
        gainsTenthDb: p.gains == nullptr ? const [] : List<int>.unmodifiable(p.gains.asTypedList(p.gain_count)),
        supportsBiasTee: p.supports_bias_tee != 0,
      );
    case terra_event_type.TERRA_EVENT_TUNED:
      return TunedEvent(u.tuned.frequency_hz);
    case terra_event_type.TERRA_EVENT_SIGNAL:
      final p = u.signal;
      return SignalEvent(
        rmsDbfs: p.rms_dbfs,
        peakDbfs: p.peak_dbfs,
        clipRatio: p.clip_ratio,
        channelDbfs: p.channel_dbfs,
        noiseDbfs: p.noise_dbfs,
        snrDb: p.snr_db,
        gainTenthDb: p.gain_tenth_db,
      );
    case terra_event_type.TERRA_EVENT_SPECTRUM:
      final p = u.spectrum;
      return SpectrumEvent(
        centerHz: p.center_hz,
        spanHz: p.span_hz,
        binsDb: p.bins_db == nullptr ? Float32List(0) : Float32List.fromList(p.bins_db.asTypedList(p.bins_count)),
      );
    case terra_event_type.TERRA_EVENT_GAIN:
      final p = u.gain;
      return GainEvent(GainMode.fromCode(p.mode), p.gain_tenth_db, converged: p.converged != 0);
    case terra_event_type.TERRA_EVENT_HD_SYNC:
      final p = u.hd_sync;
      return HdSyncEvent(synced: p.synced != 0, freqOffsetHz: p.freq_offset_hz, psmi: p.psmi);
    case terra_event_type.TERRA_EVENT_HD_QUALITY:
      final p = u.hd_quality;
      return HdQualityEvent(merLowerDb: p.mer_lower_db, merUpperDb: p.mer_upper_db, ber: p.ber);
    case terra_event_type.TERRA_EVENT_HD_STATION_ID:
      final p = u.hd_station;
      return HdStationIdEvent(countryCode: _string(p.country_code), facilityId: p.fcc_facility_id);
    case terra_event_type.TERRA_EVENT_HD_STATION_NAME:
      return HdStationTextEvent(HdStationText.name, _string(u.hd_station.text));
    case terra_event_type.TERRA_EVENT_HD_STATION_SLOGAN:
      return HdStationTextEvent(HdStationText.slogan, _string(u.hd_station.text));
    case terra_event_type.TERRA_EVENT_HD_STATION_MESSAGE:
      return HdStationTextEvent(HdStationText.message, _string(u.hd_station.text));
    case terra_event_type.TERRA_EVENT_HD_STATION_LOCATION:
      final p = u.hd_station;
      return HdStationLocationEvent(latitude: p.latitude, longitude: p.longitude, altitudeM: p.altitude_m);
    case terra_event_type.TERRA_EVENT_HD_PROGRAM:
      final p = u.hd_program;
      return HdProgramEvent(
        program: p.program,
        restricted: p.access != 0,
        programType: p.program_type,
        programTypeName: _string(p.program_type_name),
        blendControl: p.blend_control,
      );
    case terra_event_type.TERRA_EVENT_HD_ID3:
      final p = u.hd_id3;
      return HdId3Event(
        program: p.program,
        title: _string(p.title),
        artist: _string(p.artist),
        album: _string(p.album),
        genre: _string(p.genre),
        comment: _string(p.comment),
        xhdrParam: p.xhdr_param,
        xhdrLot: p.xhdr_lot,
      );
    case terra_event_type.TERRA_EVENT_HD_LOT:
      final p = u.hd_lot;
      return HdLotEvent(
        program: p.program,
        role: LotRole.fromCode(p.role),
        lotId: p.lot_id,
        port: p.port,
        mime: p.mime,
        name: _string(p.name) ?? '',
        data: _bytes(p.data, p.size),
        isImage: p.is_image != 0,
        expiry: p.expiry_unix > 0 ? DateTime.fromMillisecondsSinceEpoch(p.expiry_unix * 1000, isUtc: true) : null,
      );
    case terra_event_type.TERRA_EVENT_HD_ALERT:
      final p = u.hd_alert;
      return HdAlertEvent(_string(p.message), category1: p.category1, category2: p.category2);
    case terra_event_type.TERRA_EVENT_HD_HERE_IMAGE:
      final p = u.hd_here_image;
      return HdHereImageEvent(
        imageType: p.image_type,
        seq: p.seq,
        n1: p.n1,
        n2: p.n2,
        name: _string(p.name),
        data: _bytes(p.data, p.size),
        north: p.latitude1,
        west: p.longitude1,
        south: p.latitude2,
        east: p.longitude2,
        time: p.time_unix > 0 ? DateTime.fromMillisecondsSinceEpoch(p.time_unix * 1000, isUtc: true) : null,
      );
    case terra_event_type.TERRA_EVENT_FM_STATUS:
      final p = u.fm_status;
      return FmStatusEvent(
        cnrDb: p.cnr_db,
        pilotLevel: p.pilot_level,
        stereo: p.stereo != 0,
        stereoBlend: p.stereo_blend,
        squelched: p.squelched != 0,
        rdsSynced: p.rds_synced != 0,
        rdsBlockErrorRate: p.rds_block_error_rate,
      );
    case terra_event_type.TERRA_EVENT_RDS:
      final p = u.rds;
      return RdsEvent(
        pi: p.pi < 0 ? null : p.pi,
        pty: p.pty < 0 ? null : p.pty,
        tp: p.tp != 0,
        ta: p.ta != 0,
        music: p.ms != 0,
        ps: _string(p.ps),
        radioText: _string(p.rt),
      );
    case terra_event_type.TERRA_EVENT_AUDIO_STATUS:
      final p = u.audio_status;
      return AudioStatusEvent(
        active: AudioSource.fromCode(p.active),
        hdAvailable: p.hd_available != 0,
        program: p.program,
        mode: AudioMode.fromCode(p.mode),
        bufferMs: p.buffer_ms,
        underruns: p.underruns,
        levelLeftDb: p.level_left_db,
        levelRightDb: p.level_right_db,
        deviceRunning: p.device_running != 0,
        deviceSampleRate: p.device_sample_rate,
      );
  }
  return null;
}

String? _string(Pointer<Char> p) {
  if (p == nullptr) return null;
  final bytes = p.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
}

Uint8List _bytes(Pointer<Uint8> p, int size) =>
    p == nullptr || size <= 0 ? Uint8List(0) : Uint8List.fromList(p.asTypedList(size));
