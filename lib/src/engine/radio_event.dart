import 'dart:typed_data';

import 'radio_types.dart';

/// Everything the engine reports. Payloads are plain Dart copies; nothing
/// here points into native memory.
sealed class RadioEvent {
  const RadioEvent();
}

final class LogEvent extends RadioEvent {
  const LogEvent(this.level, this.tag, this.message);
  final EngineLogLevel level;
  final String tag;
  final String message;
}

final class SourceStateEvent extends RadioEvent {
  const SourceStateEvent(this.state, {this.errorCode = 0, this.message});
  final SourceState state;
  final int errorCode;
  final String? message;
}

final class DeviceInfoEvent extends RadioEvent {
  const DeviceInfoEvent({
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

final class TunedEvent extends RadioEvent {
  const TunedEvent(this.frequencyHz);
  final int frequencyHz;
}

final class SignalEvent extends RadioEvent {
  const SignalEvent({
    required this.rmsDbfs,
    required this.peakDbfs,
    required this.clipRatio,
    required this.channelDbfs,
    required this.noiseDbfs,
    required this.snrDb,
    required this.gainTenthDb,
  });
  final double rmsDbfs;
  final double peakDbfs;
  final double clipRatio;
  final double channelDbfs;
  final double noiseDbfs;
  final double snrDb;
  final int gainTenthDb;
}

final class SpectrumEvent extends RadioEvent {
  const SpectrumEvent({required this.centerHz, required this.spanHz, required this.binsDb});
  final int centerHz;
  final int spanHz;

  /// dBFS, lowest frequency first.
  final Float32List binsDb;

  double binFrequencyHz(int index) => centerHz - spanHz / 2 + (index + 0.5) * spanHz / binsDb.length;
}

final class GainEvent extends RadioEvent {
  const GainEvent(this.mode, this.gainTenthDb, {required this.converged});
  final GainMode mode;
  final int gainTenthDb;
  final bool converged;
}

final class HdSyncEvent extends RadioEvent {
  const HdSyncEvent({required this.synced, this.freqOffsetHz = 0, this.psmi = 0});
  final bool synced;
  final double freqOffsetHz;
  final int psmi;
}

final class HdQualityEvent extends RadioEvent {
  const HdQualityEvent({required this.merLowerDb, required this.merUpperDb, required this.ber});
  final double merLowerDb;
  final double merUpperDb;
  final double ber;
}

final class HdStationIdEvent extends RadioEvent {
  const HdStationIdEvent({required this.countryCode, required this.facilityId});
  final String? countryCode;
  final int facilityId;
}

final class HdStationTextEvent extends RadioEvent {
  const HdStationTextEvent(this.kind, this.text);
  final HdStationText kind;
  final String? text;
}

final class HdStationLocationEvent extends RadioEvent {
  const HdStationLocationEvent({required this.latitude, required this.longitude, required this.altitudeM});
  final double latitude;
  final double longitude;
  final int altitudeM;
}

final class HdProgramEvent extends RadioEvent {
  const HdProgramEvent({
    required this.program,
    this.restricted = false,
    this.programType = 0,
    this.programTypeName,
    this.blendControl = -1,
  });
  final int program;
  final bool restricted;
  final int programType;
  final String? programTypeName;
  final int blendControl;
}

final class HdId3Event extends RadioEvent {
  const HdId3Event({
    required this.program,
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.comment,
    this.xhdrParam = -1,
    this.xhdrLot = -1,
  });
  final int program;
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final String? comment;

  /// -1 absent, 0 show the image with [xhdrLot], 1 clear the image.
  final int xhdrParam;
  final int xhdrLot;
}

final class HdLotEvent extends RadioEvent {
  const HdLotEvent({
    required this.program,
    required this.role,
    required this.lotId,
    required this.port,
    required this.mime,
    required this.name,
    required this.data,
    required this.isImage,
    this.expiry,
  });

  /// -1 when not tied to an audio program.
  final int program;
  final LotRole role;
  final int lotId;
  final int port;
  final int mime;
  final String name;
  final Uint8List data;
  final bool isImage;
  final DateTime? expiry;
}

final class HdAlertEvent extends RadioEvent {
  const HdAlertEvent(this.message, {this.category1 = 0, this.category2 = 0});
  final String? message;
  final int category1;
  final int category2;
}

/// HERE traffic (type 8) map tiles and weather (type 13) radar images.
final class HdHereImageEvent extends RadioEvent {
  const HdHereImageEvent({
    required this.imageType,
    required this.seq,
    required this.n1,
    required this.n2,
    required this.name,
    required this.data,
    this.north = 0,
    this.west = 0,
    this.south = 0,
    this.east = 0,
    this.time,
  });

  static const traffic = 8;
  static const weather = 13;

  final int imageType;
  final int seq;

  /// Traffic: tile number 1..[n2]. Weather: sequence number.
  final int n1;
  final int n2;
  final String? name;
  final Uint8List data;

  /// Map edges in degrees, as broadcast.
  final double north;
  final double west;
  final double south;
  final double east;

  /// Broadcast time of the map (UTC).
  final DateTime? time;
}

final class FmStatusEvent extends RadioEvent {
  const FmStatusEvent({
    required this.cnrDb,
    required this.pilotLevel,
    required this.stereo,
    required this.stereoBlend,
    required this.squelched,
    required this.rdsSynced,
    required this.rdsBlockErrorRate,
  });
  final double cnrDb;
  final double pilotLevel;
  final bool stereo;
  final double stereoBlend;
  final bool squelched;
  final bool rdsSynced;
  final double rdsBlockErrorRate;
}

final class RdsEvent extends RadioEvent {
  const RdsEvent({this.pi, this.pty, this.tp = false, this.ta = false, this.music = true, this.ps, this.radioText});
  final int? pi;
  final int? pty;
  final bool tp;
  final bool ta;
  final bool music;
  final String? ps;
  final String? radioText;
}

final class AudioStatusEvent extends RadioEvent {
  const AudioStatusEvent({
    required this.active,
    required this.hdAvailable,
    required this.program,
    required this.mode,
    required this.bufferMs,
    required this.underruns,
    required this.levelLeftDb,
    required this.levelRightDb,
    required this.deviceRunning,
    required this.deviceSampleRate,
  });
  final AudioSource active;
  final bool hdAvailable;
  final int program;
  final AudioMode mode;
  final double bufferMs;
  final int underruns;
  final double levelLeftDb;
  final double levelRightDb;
  final bool deviceRunning;
  final int deviceSampleRate;
}
