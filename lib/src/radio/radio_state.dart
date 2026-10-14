import 'dart:typed_data';

import '../engine/radio_event.dart';
import '../engine/radio_types.dart';
import '../maps/map_state.dart';
import 'rbds.dart';

enum ConnectionPhase { disconnected, connecting, streaming, ended, lost, error }

const _unset = Object();

class DeviceInfo {
  const DeviceInfo({
    required this.description,
    required this.tuner,
    required this.gainsTenthDb,
    required this.supportsBiasTee,
  });
  final String description;
  final String tuner;
  final List<int> gainsTenthDb;
  final bool supportsBiasTee;
}

class HdProgramInfo {
  const HdProgramInfo({
    required this.program,
    this.typeName,
    this.programType = 0,
    this.restricted = false,
  });
  final int program;
  final String? typeName;
  final int programType;
  final bool restricted;

  String get label => 'HD${program + 1}';
}

class NowPlaying {
  const NowPlaying({
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.xhdrParam = -1,
    this.xhdrLot = -1,
  });
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final int xhdrParam;
  final int xhdrLot;

  bool sameTrack(NowPlaying other) =>
      title == other.title && artist == other.artist && album == other.album;

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      sameTrack(other) &&
      genre == other.genre &&
      xhdrParam == other.xhdrParam &&
      xhdrLot == other.xhdrLot;

  @override
  int get hashCode =>
      Object.hash(title, artist, album, genre, xhdrParam, xhdrLot);
}

class HdImage {
  const HdImage({
    required this.lotId,
    required this.bytes,
    required this.name,
    this.expiry,
  });
  final int lotId;
  final Uint8List bytes;
  final String name;
  final DateTime? expiry;
}

class HdState {
  const HdState({
    this.synced = false,
    this.merDb,
    this.ber,
    this.name,
    this.slogan,
    this.message,
    this.countryCode,
    this.facilityId,
    this.latitude,
    this.longitude,
    this.programs = const {},
    this.nowPlaying = const {},
    this.images = const {},
    this.latestPrimaryImage = const {},
    this.logos = const {},
    this.alert,
  });

  static const maxImages = 24;

  final bool synced;

  /// Mean of the lower/upper sideband MER.
  final double? merDb;
  final double? ber;
  final String? name;
  final String? slogan;
  final String? message;
  final String? countryCode;
  final int? facilityId;
  final double? latitude;
  final double? longitude;
  final Map<int, HdProgramInfo> programs;
  final Map<int, NowPlaying> nowPlaying;

  /// Primary images by LOT id (bounded to [maxImages], oldest dropped).
  final Map<int, HdImage> images;

  /// program -> LOT id of the newest primary image for that program.
  final Map<int, int> latestPrimaryImage;

  /// program (-1 = station-wide) -> logo.
  final Map<int, HdImage> logos;
  final String? alert;

  bool get isHdStation => synced || programs.isNotEmpty || name != null;

  /// Album/program art for [program], or null when the station shows none.
  HdImage? artFor(int program) {
    final np = nowPlaying[program];
    if (np != null && np.xhdrParam == 1) return null;
    if (np != null && np.xhdrParam == 0 && np.xhdrLot >= 0) {
      return images[np.xhdrLot];
    }
    final latest = latestPrimaryImage[program];
    return latest == null ? null : images[latest];
  }

  HdImage? logoFor(int program) => logos[program] ?? logos[-1] ?? logos[0];

  HdState copyWith({
    bool? synced,
    Object? merDb = _unset,
    Object? ber = _unset,
    Object? name = _unset,
    Object? slogan = _unset,
    Object? message = _unset,
    Object? countryCode = _unset,
    Object? facilityId = _unset,
    Object? latitude = _unset,
    Object? longitude = _unset,
    Map<int, HdProgramInfo>? programs,
    Map<int, NowPlaying>? nowPlaying,
    Map<int, HdImage>? images,
    Map<int, int>? latestPrimaryImage,
    Map<int, HdImage>? logos,
    Object? alert = _unset,
  }) {
    return HdState(
      synced: synced ?? this.synced,
      merDb: merDb == _unset ? this.merDb : merDb as double?,
      ber: ber == _unset ? this.ber : ber as double?,
      name: name == _unset ? this.name : name as String?,
      slogan: slogan == _unset ? this.slogan : slogan as String?,
      message: message == _unset ? this.message : message as String?,
      countryCode: countryCode == _unset
          ? this.countryCode
          : countryCode as String?,
      facilityId: facilityId == _unset ? this.facilityId : facilityId as int?,
      latitude: latitude == _unset ? this.latitude : latitude as double?,
      longitude: longitude == _unset ? this.longitude : longitude as double?,
      programs: programs ?? this.programs,
      nowPlaying: nowPlaying ?? this.nowPlaying,
      images: images ?? this.images,
      latestPrimaryImage: latestPrimaryImage ?? this.latestPrimaryImage,
      logos: logos ?? this.logos,
      alert: alert == _unset ? this.alert : alert as String?,
    );
  }
}

class RdsState {
  const RdsState({
    this.pi,
    this.pty,
    this.ps,
    this.radioText,
    this.tp = false,
    this.ta = false,
  });
  final int? pi;
  final int? pty;
  final String? ps;
  final String? radioText;
  final bool tp;
  final bool ta;

  /// North American call sign derived from [pi] (RBDS), if any.
  String? get callSign => pi == null ? null : callSignFromPi(pi!);

  String? get psTrimmed {
    final t = ps?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}

class FmState {
  const FmState({this.status, this.rds = const RdsState()});
  final FmStatusEvent? status;
  final RdsState rds;

  FmState copyWith({Object? status = _unset, RdsState? rds}) => FmState(
    status: status == _unset ? this.status : status as FmStatusEvent?,
    rds: rds ?? this.rds,
  );
}

class RadioState {
  const RadioState({
    this.phase = ConnectionPhase.disconnected,
    this.errorMessage,
    this.sourceLabel,
    this.device,
    this.frequencyHz,
    this.program = 0,
    this.audioMode = AudioMode.auto,
    this.gain,
    this.signal,
    this.spectrum,
    this.hd = const HdState(),
    this.fm = const FmState(),
    this.audio,
    this.maps = const MapsState(),
  });

  final ConnectionPhase phase;
  final String? errorMessage;
  final String? sourceLabel;
  final DeviceInfo? device;
  final int? frequencyHz;

  /// Selected HD program (0 = HD1).
  final int program;
  final AudioMode audioMode;
  final GainEvent? gain;
  final SignalEvent? signal;
  final SpectrumEvent? spectrum;
  final HdState hd;
  final FmState fm;
  final AudioStatusEvent? audio;

  /// Traffic and weather maps. Kept across retunes: they describe the
  /// region, not the station.
  final MapsState maps;

  bool get isStreaming => phase == ConnectionPhase.streaming;

  AudioSource get audible => audio?.active ?? AudioSource.none;

  /// Best available station name: HD short name, RDS PS, then RBDS call sign.
  String? get stationName => hd.name ?? fm.rds.psTrimmed ?? fm.rds.callSign;

  NowPlaying? get nowPlaying {
    final hdTrack = hd.nowPlaying[program];
    if (hdTrack != null &&
        (audible == AudioSource.hd ||
            program > 0 ||
            audible == AudioSource.none)) {
      return hdTrack;
    }
    final rt = fm.rds.radioText?.trim();
    if (rt != null && rt.isNotEmpty) return NowPlaying(title: rt);
    return hdTrack;
  }

  /// Why HD is selected but is not what is playing. Null when FM was chosen,
  /// HD audio is already playing, or the output is muted.
  String? hdWaitCaption({required bool audioOn}) {
    if (!audioOn || !isStreaming || audioMode == AudioMode.analog) return null;
    if (audible == AudioSource.hd) return null;
    final waiting =
        audioMode == AudioMode.digital ||
        program > 0 ||
        hd.isHdStation ||
        hd.programs.isNotEmpty;
    if (!waiting) return null;
    return 'Buffering HD${program + 1}…';
  }

  RadioState copyWith({
    ConnectionPhase? phase,
    Object? errorMessage = _unset,
    Object? sourceLabel = _unset,
    Object? device = _unset,
    Object? frequencyHz = _unset,
    int? program,
    AudioMode? audioMode,
    Object? gain = _unset,
    Object? signal = _unset,
    Object? spectrum = _unset,
    HdState? hd,
    FmState? fm,
    Object? audio = _unset,
    MapsState? maps,
  }) {
    return RadioState(
      phase: phase ?? this.phase,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
      sourceLabel: sourceLabel == _unset
          ? this.sourceLabel
          : sourceLabel as String?,
      device: device == _unset ? this.device : device as DeviceInfo?,
      frequencyHz: frequencyHz == _unset
          ? this.frequencyHz
          : frequencyHz as int?,
      program: program ?? this.program,
      audioMode: audioMode ?? this.audioMode,
      gain: gain == _unset ? this.gain : gain as GainEvent?,
      signal: signal == _unset ? this.signal : signal as SignalEvent?,
      spectrum: spectrum == _unset ? this.spectrum : spectrum as SpectrumEvent?,
      hd: hd ?? this.hd,
      fm: fm ?? this.fm,
      audio: audio == _unset ? this.audio : audio as AudioStatusEvent?,
      maps: maps ?? this.maps,
    );
  }
}
