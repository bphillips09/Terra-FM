/// Where IQ samples come from.
sealed class SourceConfig {
  const SourceConfig();

  /// Human-readable label for the UI.
  String get label;
}

/// Android: a file descriptor from `UsbDeviceConnection.getFileDescriptor()`.
/// The connection must stay open on the Kotlin side while streaming.
final class UsbFdSource extends SourceConfig {
  const UsbFdSource(this.fd, {this.deviceName = 'Tuner'});
  final int fd;
  final String deviceName;

  @override
  String get label => deviceName;
}

/// Desktop: librtlsdr device index (see `RadioEngine.listUsbDevices`).
final class UsbIndexSource extends SourceConfig {
  const UsbIndexSource(this.index, {this.deviceName = 'Tuner'});
  final int index;
  final String deviceName;

  @override
  String get label => deviceName;
}

final class RtlTcpSource extends SourceConfig {
  const RtlTcpSource(this.host, {this.port = 1234});
  final String host;
  final int port;

  @override
  String get label => 'rtl_tcp $host:$port';
}

/// Raw unsigned 8-bit IQ captured at 1,488,375 S/s (e.g. nrsc5 `-w`).
final class FileSource extends SourceConfig {
  const FileSource(this.path, {this.realtime = true, this.loop = false, this.frequencyHz});
  final String path;
  final bool realtime;
  final bool loop;

  /// Frequency the capture was recorded at, for display.
  final int? frequencyHz;

  @override
  String get label => 'File ${path.split(RegExp(r'[/\\]')).last}';
}
