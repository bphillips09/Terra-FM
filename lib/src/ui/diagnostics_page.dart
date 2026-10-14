import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../app.dart';
import '../logging/log_buffer.dart';
import '../radio/radio_controller.dart';
import '../settings/settings.dart';
import 'widgets/radio_select.dart';
import 'widgets/spectrum_view.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  RadioController? _radio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_radio == null) {
      _radio = context.radio;
      _radio!.acquireSpectrum();
    }
  }

  @override
  void dispose() {
    _radio?.releaseSpectrum();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          RadioSelect(
            select: (r) => r.state.spectrum,
            builder: (context, spectrum) => Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SpectrumView(spectrum: spectrum),
              ),
            ),
          ),
          const _Metrics(),
          const _LogView(),
        ],
      ),
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics();

  @override
  Widget build(BuildContext context) {
    return RadioSelect(
      select: (r) =>
          (r.state.signal, r.state.gain, r.state.hd, r.state.fm, r.state.audio),
      builder: (context, v) {
        final (signal, gain, hd, fm, audio) = v;
        String db(double? x) => x == null ? '—' : '${x.toStringAsFixed(1)} dB';
        final fmStatus = fm.status;
        final rds = fm.rds;
        return _CardGrid(
          children: [
            _MetricCard('Signal', {
              'Channel': db(signal?.channelDbfs),
              'Noise': db(signal?.noiseDbfs),
              'SNR': db(signal?.snrDb),
              'RMS / peak': signal == null
                  ? '—'
                  : '${signal.rmsDbfs.toStringAsFixed(1)} / ${signal.peakDbfs.toStringAsFixed(1)} dBFS',
              'Clipping': signal == null
                  ? '—'
                  : '${(signal.clipRatio * 100).toStringAsFixed(2)} %',
              'Gain': gain == null
                  ? '—'
                  : '${(gain.gainTenthDb / 10).toStringAsFixed(1)} dB ${gain.mode.name}${gain.converged ? ' ✓' : ''}',
            }),
            _MetricCard('HD', {
              'Sync': hd.synced ? 'locked' : 'searching',
              'MER': db(hd.merDb),
              'BER': hd.ber == null ? '—' : hd.ber!.toStringAsExponential(1),
              'Station': [
                hd.name,
                if (hd.facilityId != null) 'FCC ${hd.facilityId}',
              ].whereType<String>().join(' · '),
              'Programs': hd.programs.values
                  .map(
                    (p) =>
                        '${p.label}${p.typeName == null ? '' : ' ${p.typeName}'}',
                  )
                  .join(', '),
              if (hd.latitude != null)
                'Location':
                    '${hd.latitude!.toStringAsFixed(3)}, ${hd.longitude!.toStringAsFixed(3)}',
            }),
            _MetricCard('Analog FM', {
              'CNR': db(fmStatus?.cnrDb),
              'Stereo': fmStatus == null
                  ? '—'
                  : fmStatus.stereo
                  ? 'pilot locked · ${(fmStatus.stereoBlend * 100).round()} %'
                  : 'mono',
              'Squelch': fmStatus == null
                  ? '—'
                  : (fmStatus.squelched ? 'muted' : 'open'),
              'RDS': fmStatus == null
                  ? '—'
                  : fmStatus.rdsSynced
                  ? 'sync · BLER ${(fmStatus.rdsBlockErrorRate * 100).round()} %'
                  : 'no sync',
              'PI': rds.pi == null
                  ? '—'
                  : '0x${rds.pi!.toRadixString(16).toUpperCase()} ${rds.callSign ?? ''}',
              'PS': rds.ps ?? '—',
              'RadioText': rds.radioText ?? '—',
            }),
            _MetricCard('Audio', {
              'Playing': audio?.active.name ?? '—',
              'HD available': audio == null
                  ? '—'
                  : (audio.hdAvailable ? 'yes' : 'no'),
              'Buffer': audio == null ? '—' : '${audio.bufferMs.round()} ms',
              'Underruns': '${audio?.underruns ?? '—'}',
              'Level L/R': audio == null
                  ? '—'
                  : '${audio.levelLeftDb.toStringAsFixed(0)} / ${audio.levelRightDb.toStringAsFixed(0)} dBFS',
              'Device': audio == null
                  ? '—'
                  : '${audio.deviceRunning ? 'running' : 'stopped'} @ ${audio.deviceSampleRate} Hz',
            }),
          ],
        );
      },
    );
  }
}

/// Equal-width cards that fill each row, the same height across a row, with
/// the same gaps as the cards above and below.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});
  final List<Widget> children;

  static const _minWidth = 280.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final fit = (c.maxWidth ~/ _minWidth).clamp(1, children.length);
        // Balanced rows: four cards on a three-wide screen are 2 + 2, not 3 + 1.
        final rows = (children.length / fit).ceil();
        final columns = (children.length / rows).ceil();
        return Column(
          children: [
            for (var i = 0; i < children.length; i += columns)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + columns; j++)
                      Expanded(
                        child: j < children.length
                            ? children[j]
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.title, this.rows);
  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final e in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(e.key, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(
                        e.value.isEmpty ? '—' : e.value,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView();

  @override
  Widget build(BuildContext context) {
    final logs = AppScope.of(context).logs;
    final theme = Theme.of(context);
    return Card(
      child: ListenableBuilder(
        listenable: logs,
        builder: (context, _) {
          final records = logs.records.toList().reversed.take(200).toList();
          return ExpansionTile(
            title: const Text('Log'),
            subtitle: Text('${logs.records.length} entries'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<LogDetail>(
                  tooltip: 'Log detail',
                  initialValue: effectiveLogDetail(
                    context.radio.settings.logLevel,
                  ),
                  onSelected: context.radio.setLogLevel,
                  itemBuilder: (context) => [
                    for (final level in LogDetail.values)
                      PopupMenuItem(value: level, child: Text(level.label)),
                  ],
                  icon: const Icon(Icons.tune),
                ),
                IconButton(
                  tooltip: 'Copy all',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: logs.export()));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Log copied')));
                  },
                ),
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: logs.clear,
                ),
              ],
            ),
            children: [
              SizedBox(
                height: 320,
                child: ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (context, i) {
                    final r = records[i];
                    final color = r.level >= Level.SEVERE
                        ? theme.colorScheme.error
                        : r.level >= Level.WARNING
                        ? theme.colorScheme.tertiary
                        : r.level >= Level.INFO
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant;
                    final t = r.time;
                    final ts =
                        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
                    final level = r.level >= Level.SEVERE
                        ? 'ERROR'
                        : r.level >= Level.WARNING
                        ? 'WARN'
                        : r.level.name;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 1,
                      ),
                      child: Text(
                        '$ts $level ${r.loggerName}: ${r.message}${r.error == null ? '' : ' (${r.error})'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: color,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
