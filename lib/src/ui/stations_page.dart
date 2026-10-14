import 'package:flutter/material.dart';

import '../app.dart';
import '../radio/band_plan.dart';
import '../radio/radio_controller.dart';
import '../settings/settings.dart';
import 'widgets/content_frame.dart';
import 'widgets/preset_logo.dart';
import 'widgets/radio_select.dart';
import 'widgets/signal_bars.dart';

class StationsPage extends StatelessWidget {
  const StationsPage({super.key, required this.onTuned});

  /// Called after the user picks a station (switches back to Listen).
  final VoidCallback onTuned;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stations'),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(kTextTabBarHeight),
            child: Center(
              child: SizedBox(
                width: 840,
                child: TabBar(
                  tabs: [
                    Tab(text: 'Presets'),
                    Tab(text: 'Band scan'),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: ContentFrame(
          child: TabBarView(
            children: [
              _PresetList(onTuned: onTuned),
              _ScanList(onTuned: onTuned),
            ],
          ),
        ),
      ),
    );
  }
}

String _channelLabel(int frequencyHz, int program) =>
    '${formatMhz(frequencyHz)} MHz${program > 0 ? ' · HD${program + 1}' : ''}';

class _PresetList extends StatelessWidget {
  const _PresetList({required this.onTuned});
  final VoidCallback onTuned;

  @override
  Widget build(BuildContext context) {
    return RadioSelect(
      select: (r) => (r.settings.presets, r.settings.presetCount),
      builder: (context, v) {
        final (presets, count) = v;
        final radio = context.radio;
        final slots = presetSlots(presets, count);
        return ReorderableListView.builder(
          itemCount: slots.length,
          onReorderItem: radio.reorderPresets,
          itemBuilder: (context, i) {
            final p = slots[i];
            if (p == null) {
              return ListTile(
                key: ValueKey('empty-$i'),
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text('Preset ${i + 1}'),
                subtitle: const Text('Empty'),
              );
            }
            return Dismissible(
              key: ValueKey('slot-$i-${p.frequencyHz}-${p.program}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) => radio.clearPreset(i),
              child: ListTile(
                leading: PresetLogo(
                  preset: p,
                  size: 48,
                  placeholder: CircleAvatar(child: Text('${i + 1}')),
                ),
                title: Text(p.name ?? _channelLabel(p.frequencyHz, p.program)),
                subtitle: p.name == null
                    ? null
                    : Text(_channelLabel(p.frequencyHz, p.program)),
                trailing: IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _rename(context, p),
                ),
                onTap: () {
                  radio.tune(p.frequencyHz, program: p.program);
                  onTuned();
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, Preset preset) async {
    final radio = context.radio;
    final controller = TextEditingController(text: preset.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Preset name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (s) => Navigator.pop(context, s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) radio.renamePreset(preset, name);
  }
}

class _ScanList extends StatelessWidget {
  const _ScanList({required this.onTuned});
  final VoidCallback onTuned;

  @override
  Widget build(BuildContext context) {
    return RadioSelect(
      select: (r) => (
        r.settings.stations,
        r.scan,
        r.state.isStreaming,
        r.state.frequencyHz,
      ),
      builder: (context, v) {
        final (stations, scan, streaming, tuned) = v;
        final radio = context.radio;
        final list = scan.phase == ScanPhase.identifying
            ? scan.found
            : stations;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: scan.active
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                scan.phase == ScanPhase.sweeping
                                    ? 'Sweeping the band…'
                                    : 'Identifying stations…',
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: scan.progress),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                stations.isEmpty
                                    ? 'Scan to find stations in ${radio.band.label}.'
                                    : '${stations.length} stations · ${stations.where((s) => s.hd).length} with HD',
                              ),
                              if (scan.error case final error?)
                                Text(
                                  error,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 12),
                  if (scan.active)
                    OutlinedButton(
                      onPressed: radio.cancelScan,
                      child: const Text('Stop'),
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.radar),
                      label: const Text('Scan'),
                      onPressed: streaming ? radio.scanBand : null,
                    ),
                  if (!scan.active && stations.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear list',
                      icon: const Icon(Icons.clear_all),
                      onPressed: radio.clearStations,
                    ),
                ],
              ),
            ),
            if (!streaming && !scan.active)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Connect a receiver to scan.'),
              ),
            Expanded(
              child: list.isEmpty
                  ? const _Empty(
                      icon: Icons.radar,
                      text: 'No stations found yet.',
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final s = list[i];
                        final detail = [
                          '${formatMhz(s.frequencyHz)} MHz',
                          ?s.category,
                        ].join(' · ');
                        return ListTile(
                          selected: s.frequencyHz == tuned,
                          leading: PresetLogo(
                            preset: Preset(frequencyHz: s.frequencyHz),
                            size: 48,
                            placeholder: const _LogoPlaceholder(),
                          ),
                          title: Text(
                            s.name ?? (scan.active ? '…' : 'Unknown'),
                          ),
                          subtitle: Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 12,
                            children: [
                              if (s.hd)
                                Chip(
                                  label: Text(
                                    s.programs > 1 ? 'HD1–${s.programs}' : 'HD',
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              _Strength(snrDb: s.snrDb),
                            ],
                          ),
                          onTap: scan.active
                              ? null
                              : () {
                                  radio.tune(s.frequencyHz);
                                  onTuned();
                                },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Same placeholder as a preset without a logo.
class _LogoPlaceholder extends StatelessWidget {
  const _LogoPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.radio, size: 26, color: scheme.onSurfaceVariant),
    );
  }
}

/// Signal bars over the level, in a fixed width so rows line up.
class _Strength extends StatelessWidget {
  const _Strength({required this.snrDb});
  final double? snrDb;

  @override
  Widget build(BuildContext context) {
    final snr = snrDb;
    final theme = Theme.of(context);
    return SizedBox(
      width: 48,
      child: snr == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                SignalBars(quality: SignalBars.fromCnr(snr), size: 16),
                Text(
                  '${snr.toStringAsFixed(0)} dB',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
