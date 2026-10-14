import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/audio/media_session.dart';
import 'src/devices/device_service.dart';
import 'src/logging/log_buffer.dart';
import 'src/native/native_engine.dart';
import 'src/radio/art_cache.dart';
import 'src/radio/radio_controller.dart';
import 'src/settings/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final logs = LogBuffer()..attach();
  final log = Logger('app');
  FlutterError.onError = (details) {
    log.severe('Flutter error', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.severe('Uncaught error', error, stack);
    return true;
  };
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');
    yield LicenseEntryWithLineBreaks(const ['terra_core (native)'], notices);
  });

  final NativeRadioEngine engine;
  try {
    // After a hot restart the previous isolate's engine is still running and
    // holding the receiver.
    final orphans = await NativeRadioEngine.releaseOrphans();
    if (orphans > 0) log.info('Stopped $orphans engine(s) left running by a hot restart');
    engine = NativeRadioEngine();
  } on Object catch (e, st) {
    log.severe('Native engine failed to load', e, st);
    runApp(
      _FatalErrorApp(
        'The radio engine (libterra_core) could not be loaded.\n\n$e',
      ),
    );
    return;
  }
  log.info('terra_core ${engine.version} on ${Platform.operatingSystem}');

  final support = await getApplicationSupportDirectory();
  final art = ArtCache(Directory('${support.path}/art'));
  final controller = RadioController(
    engine: engine,
    settingsStore: SettingsStore(await PrefsKeyValueStore.open()),
    devices: createDeviceService(engine),
    artCache: art,
    logs: logs,
  );
  await initMediaSession(controller, art);

  runApp(TerraApp(controller: controller, logs: logs));
  unawaited(controller.start());
}

class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(message),
          ),
        ),
      ),
    );
  }
}
