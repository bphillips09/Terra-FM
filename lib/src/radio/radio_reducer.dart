import '../engine/radio_event.dart';
import '../engine/radio_types.dart';
import '../maps/map_state.dart';
import 'radio_state.dart';

/// Folds one engine event into the state. Pure: no I/O, no clocks.
/// Sub-objects are only replaced when they change, so widgets can compare
/// them by identity.
RadioState reduceRadioState(RadioState s, RadioEvent e) {
  switch (e) {
    case LogEvent():
      return s;
    case SourceStateEvent(:final state, :final message):
      return switch (state) {
        SourceState.opening => s.copyWith(
          phase: ConnectionPhase.connecting,
          errorMessage: null,
        ),
        SourceState.streaming => s.copyWith(
          phase: ConnectionPhase.streaming,
          errorMessage: null,
        ),
        SourceState.ended => s.copyWith(phase: ConnectionPhase.ended),
        SourceState.lost => _offline(
          s,
          ConnectionPhase.lost,
          message ?? 'Device disconnected',
        ),
        SourceState.error => _offline(
          s,
          ConnectionPhase.error,
          message ?? 'Tuner error',
        ),
        SourceState.closed =>
          s.phase == ConnectionPhase.lost || s.phase == ConnectionPhase.error
              ? s
              : _offline(s, ConnectionPhase.disconnected, null),
      };
    case DeviceInfoEvent():
      return s.copyWith(
        device: DeviceInfo(
          description: e.description,
          tuner: e.tuner,
          gainsTenthDb: e.gainsTenthDb,
          supportsBiasTee: e.supportsBiasTee,
        ),
      );
    case TunedEvent(:final frequencyHz):
      if (frequencyHz == s.frequencyHz) return s;
      return s.copyWith(
        frequencyHz: frequencyHz,
        hd: const HdState(),
        fm: const FmState(),
        signal: null,
        audio: null,
      );
    case SignalEvent():
      return s.copyWith(signal: e);
    case SpectrumEvent():
      return s.copyWith(spectrum: e);
    case GainEvent():
      return s.copyWith(gain: e);
    case HdSyncEvent(:final synced):
      if (synced == s.hd.synced) return s;
      return s.copyWith(
        hd: s.hd.copyWith(synced: synced, merDb: synced ? s.hd.merDb : null),
      );
    case HdQualityEvent():
      return s.copyWith(
        hd: s.hd.copyWith(merDb: (e.merLowerDb + e.merUpperDb) / 2, ber: e.ber),
      );
    case HdStationIdEvent():
      return s.copyWith(
        hd: s.hd.copyWith(countryCode: e.countryCode, facilityId: e.facilityId),
      );
    case HdStationTextEvent(:final kind, :final text):
      final hd = switch (kind) {
        HdStationText.name => s.hd.copyWith(name: text),
        HdStationText.slogan => s.hd.copyWith(slogan: text),
        HdStationText.message => s.hd.copyWith(message: text),
      };
      return s.copyWith(hd: hd);
    case HdStationLocationEvent():
      return s.copyWith(
        hd: s.hd.copyWith(latitude: e.latitude, longitude: e.longitude),
      );
    case HdProgramEvent():
      final info = HdProgramInfo(
        program: e.program,
        typeName: e.programTypeName,
        programType: e.programType,
        restricted: e.restricted,
      );
      final existing = s.hd.programs[e.program];
      if (existing != null &&
          existing.typeName == info.typeName &&
          existing.programType == info.programType &&
          existing.restricted == info.restricted) {
        return s;
      }
      return s.copyWith(
        hd: s.hd.copyWith(programs: {...s.hd.programs, e.program: info}),
      );
    case HdId3Event():
      final np = NowPlaying(
        title: e.title,
        artist: e.artist,
        album: e.album,
        genre: e.genre,
        xhdrParam: e.xhdrParam,
        xhdrLot: e.xhdrLot,
      );
      final old = s.hd.nowPlaying[e.program];
      if (old != null &&
          old.sameTrack(np) &&
          old.xhdrParam == np.xhdrParam &&
          old.xhdrLot == np.xhdrLot) {
        return s;
      }
      var programs = s.hd.programs;
      if (!programs.containsKey(e.program)) {
        programs = {...programs, e.program: HdProgramInfo(program: e.program)};
      }
      return s.copyWith(
        hd: s.hd.copyWith(
          nowPlaying: {...s.hd.nowPlaying, e.program: np},
          programs: programs,
        ),
      );
    case HdLotEvent() when isMapLot(e):
      return _withMaps(s, e);
    case HdLotEvent():
      if (!e.isImage) return s;
      final image = HdImage(
        lotId: e.lotId,
        bytes: e.data,
        name: e.name,
        expiry: e.expiry,
      );
      switch (e.role) {
        case LotRole.stationLogo:
          return s.copyWith(
            hd: s.hd.copyWith(logos: {...s.hd.logos, e.program: image}),
          );
        case LotRole.primaryImage:
        case LotRole.other:
        case LotRole.traffic:
        case LotRole.weather:
          final images = {...s.hd.images, e.lotId: image};
          while (images.length > HdState.maxImages) {
            images.remove(images.keys.first);
          }
          return s.copyWith(
            hd: s.hd.copyWith(
              images: images,
              latestPrimaryImage:
                  e.role == LotRole.primaryImage && e.program >= 0
                  ? {...s.hd.latestPrimaryImage, e.program: e.lotId}
                  : null,
            ),
          );
      }
    case HdAlertEvent(:final message):
      return s.copyWith(hd: s.hd.copyWith(alert: message));
    case HdHereImageEvent():
      return _withMaps(s, e);
    case FmStatusEvent():
      return s.copyWith(fm: s.fm.copyWith(status: e));
    case RdsEvent():
      return s.copyWith(
        fm: s.fm.copyWith(
          rds: RdsState(
            pi: e.pi,
            pty: e.pty,
            ps: e.ps,
            radioText: e.radioText,
            tp: e.tp,
            ta: e.ta,
          ),
        ),
      );
    case AudioStatusEvent():
      return s.copyWith(audio: e);
  }
}

RadioState _withMaps(RadioState s, RadioEvent e) {
  final maps = reduceMaps(s.maps, e, frequencyHz: s.frequencyHz);
  return identical(maps, s.maps) ? s : s.copyWith(maps: maps);
}

RadioState _offline(RadioState s, ConnectionPhase phase, String? message) =>
    s.copyWith(
      phase: phase,
      errorMessage: message,
      device: null,
      signal: null,
      spectrum: null,
      gain: null,
      audio: null,
      hd: const HdState(),
      fm: const FmState(),
    );
