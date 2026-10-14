import 'radio_event.dart';
import 'radio_types.dart';
import 'source_config.dart';

class RadioEngineException implements Exception {
  const RadioEngineException(this.message, {this.code = -1});
  final String message;
  final int code;

  @override
  String toString() => 'RadioEngineException($code): $message';
}

/// Commands into the receiver plus its event stream. The production
/// implementation is `NativeRadioEngine` (FFI to terra_core); tests use fakes.
abstract interface class RadioEngine {
  Stream<RadioEvent> get events;

  String get version;

  /// Opens [source] and starts streaming. When [frequencyHz] is given the
  /// tuner starts there, using [gainHintTenthDb] (a previously converged auto
  /// gain) to skip the gain search.
  Future<void> open(SourceConfig source, {int? frequencyHz, int? gainHintTenthDb});

  Future<void> close();

  void tune(int frequencyHz, {int? gainHintTenthDb});

  /// HD program: 0 = HD1.
  void setProgram(int program);

  void setAudioMode(AudioMode mode);

  void setGain(GainMode mode, {int gainTenthDb = 0});

  void setPpm(int ppm);

  void setBiasTee(bool enabled);

  void setDeemphasisUs(int microseconds);

  /// > 0 delays HD, < 0 delays analog (milliseconds).
  void setBlendAlignmentMs(int milliseconds);

  /// Analog FM mute threshold in dB of carrier-to-noise. The receiver mutes
  /// below this and opens 2 dB above it. Negative disables muting.
  void setSquelchDb(int thresholdDb);

  /// 0..1 (values above 1 amplify).
  void setVolume(double volume);

  /// HD playback level relative to analog FM. 1 matches FM.
  void setHdVolume(double level);

  void setAudioEnabled(bool enabled);

  void setSpectrumEnabled(bool enabled);

  /// Desktop USB tuners visible to librtlsdr. Always empty on Android.
  List<String> listUsbDevices();

  Future<void> dispose();
}
