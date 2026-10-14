import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../engine/radio_engine.dart';
import '../engine/source_config.dart';

class SdrDevice {
  const SdrDevice({required this.id, required this.name, this.hasPermission = true, this.serial});

  /// Android: USB device path (/dev/bus/usb/...). Desktop: librtlsdr index.
  final String id;
  final String name;
  final bool hasPermission;
  final String? serial;
}

sealed class DeviceEvent {
  const DeviceEvent(this.device);
  final SdrDevice device;
}

final class DeviceAttached extends DeviceEvent {
  const DeviceAttached(super.device);
}

final class DeviceDetached extends DeviceEvent {
  const DeviceDetached(super.device);
}

/// Finds USB tuners and turns one into a [SourceConfig].
abstract interface class DeviceService {
  Stream<DeviceEvent> get events;

  /// Whether [events] reports plug and unplug. Without it, a lost receiver
  /// has to be polled for.
  bool get hotplug;

  Future<List<SdrDevice>> listDevices();

  /// Requests permission if needed and opens the device. Returns null when
  /// the user declines.
  Future<SourceConfig?> open(SdrDevice device);

  /// Releases whatever [open] acquired (Android closes its USB connection).
  Future<void> release();

  /// The device that launched the app (Android USB attach intent), if any.
  Future<SdrDevice?> takeLaunchDevice();
}

DeviceService createDeviceService(RadioEngine engine) =>
    Platform.isAndroid ? AndroidDeviceService() : DesktopDeviceService(engine);

/// Talks to `TerraUsbPlugin.kt` (packages/terra_usb).
class AndroidDeviceService implements DeviceService {
  AndroidDeviceService() {
    _eventsChannel.receiveBroadcastStream().listen((raw) {
      final map = (raw as Map).cast<String, Object?>();
      final device = _device((map['device']! as Map).cast());
      _events.add(map['type'] == 'attached' ? DeviceAttached(device) : DeviceDetached(device));
    });
  }

  static const _channel = MethodChannel('com.bp.terra/usb');
  static const _eventsChannel = EventChannel('com.bp.terra/usb_events');
  final _events = StreamController<DeviceEvent>.broadcast();

  @override
  Stream<DeviceEvent> get events => _events.stream;

  @override
  bool get hotplug => true;

  @override
  Future<List<SdrDevice>> listDevices() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('list') ?? const [];
    return [for (final m in list) _device(m.cast())];
  }

  @override
  Future<SourceConfig?> open(SdrDevice device) async {
    final result = await _channel.invokeMapMethod<String, Object?>('open', {'id': device.id});
    if (result == null) return null;
    final fd = result['fd'] as int?;
    if (fd == null || fd < 0) {
      throw RadioEngineException((result['error'] as String?) ?? 'USB permission denied');
    }
    return UsbFdSource(fd, deviceName: device.name);
  }

  @override
  Future<void> release() => _channel.invokeMethod<void>('close');

  @override
  Future<SdrDevice?> takeLaunchDevice() async {
    final m = await _channel.invokeMapMethod<String, Object?>('takeLaunchDevice');
    return m == null ? null : _device(m);
  }

  static SdrDevice _device(Map<String, Object?> m) => SdrDevice(
    id: m['id']! as String,
    name: (m['name'] as String?) ?? 'Tuner',
    hasPermission: (m['permission'] as bool?) ?? false,
    serial: m['serial'] as String?,
  );
}

/// macOS / Linux / Windows: librtlsdr enumerates tuners itself. There is no
/// hotplug notification, so [events] is silent; the UI offers a refresh, and
/// the controller polls after a tuner drops out.
class DesktopDeviceService implements DeviceService {
  DesktopDeviceService(this._engine);

  final RadioEngine _engine;

  @override
  Stream<DeviceEvent> get events => const Stream.empty();

  @override
  bool get hotplug => false;

  @override
  Future<List<SdrDevice>> listDevices() async {
    final names = _engine.listUsbDevices();
    return [for (var i = 0; i < names.length; i++) SdrDevice(id: '$i', name: names[i])];
  }

  @override
  Future<SourceConfig?> open(SdrDevice device) async => UsbIndexSource(int.parse(device.id), deviceName: device.name);

  @override
  Future<void> release() async {}

  @override
  Future<SdrDevice?> takeLaunchDevice() async => null;
}
