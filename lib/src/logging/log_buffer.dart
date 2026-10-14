import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../settings/settings.dart';

/// Debug while debugging, Info otherwise, unless the user picked a level.
LogDetail effectiveLogDetail(LogDetail? stored) => stored ?? (kDebugMode ? LogDetail.debug : LogDetail.info);

Level levelFor(LogDetail? detail) => switch (effectiveLogDetail(detail)) {
  LogDetail.error => Level.SEVERE,
  LogDetail.warning => Level.WARNING,
  LogDetail.info => Level.INFO,
  LogDetail.debug => Level.FINE,
  LogDetail.trace => Level.FINEST,
};

/// Keeps the most recent log records for the Diagnostics screen and mirrors
/// them to the console in debug builds.
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.capacity = 1000});

  final int capacity;
  final _records = ListQueue<LogRecord>();

  Iterable<LogRecord> get records => _records;

  Level get level => Logger.root.level;

  void setLevel(Level level) {
    if (Logger.root.level == level) return;
    Logger.root.level = level;
    notifyListeners();
  }

  void attach() {
    hierarchicalLoggingEnabled = true;
    Logger.root.level = levelFor(null);
    Logger.root.onRecord.listen(add);
  }

  void add(LogRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
    if (kDebugMode) {
      debugPrint('${record.level.name.padRight(7)} ${record.loggerName}: ${record.message}'
          '${record.error == null ? '' : ' (${record.error})'}');
    }
    notifyListeners();
  }

  void clear() {
    _records.clear();
    notifyListeners();
  }

  String export() => _records
      .map((r) => '${r.time.toIso8601String()} ${r.level.name} ${r.loggerName}: ${r.message}'
          '${r.error == null ? '' : ' | ${r.error}'}')
      .join('\n');
}
