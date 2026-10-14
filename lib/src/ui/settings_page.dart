import 'package:flutter/material.dart';

import '../app.dart';
import '../engine/radio_types.dart';
import '../logging/log_buffer.dart';
import '../radio/band_plan.dart';
import '../settings/settings.dart';
import 'diagnostics_page.dart';
import 'widgets/content_frame.dart';
import 'widgets/radio_select.dart';
import 'widgets/source_picker.dart';
import 'widgets/ui_scale.dart';

const _defaultBlendAlignmentMs = 2250;

String _percent(double v) => '${(v * 100).round()}%';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ContentFrame(
        child: RadioSelect(
          select: (r) => (r.settings, r.state.device),
          builder: (context, v) {
            final (s, device) = v;
            final radio = context.radio;
            final gains = device?.gainsTenthDb ?? const <int>[];
            final biasTeeSupported = device == null || device.supportsBiasTee;
            return SliderTheme(
              // Steps still snap; a dot for each one is just noise.
              data: SliderTheme.of(context)
                  .copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  const _Section('Tuner'),
                  _Setting(
                    title: 'Source',
                    subtitle:
                        device?.description ??
                        (s.sourceKind == SourceKind.usb
                            ? 'USB tuner'
                            : 'rtl_tcp ${s.rtlTcpHost}:${s.rtlTcpPort}'),
                    trailing: device == null
                        ? const Icon(Icons.chevron_right)
                        : TextButton(
                            onPressed: radio.disconnect,
                            child: const Text('Disconnect'),
                          ),
                    onTap: () => showSourcePicker(context),
                  ),
                  _Setting(
                    title: 'Connect automatically',
                    trailing: Switch(
                      value: s.autoConnect,
                      onChanged: radio.setAutoConnect,
                    ),
                  ),
                  _Setting(
                    title: 'Region',
                    trailing: _Menu<BandPlan>(
                      value: s.band,
                      onChanged: radio.setBand,
                      items: {for (final b in BandPlan.values) b: b.label},
                    ),
                  ),
                  const _Section('Tuning'),
                  _Setting(
                    title: 'Media keys',
                    subtitle: switch (s.mediaKeys) {
                      MediaKeys.presets => 'Next and previous saved station',
                      MediaKeys.scan => 'Scan for the next station',
                      MediaKeys.step => 'Move one channel at a time',
                    },
                    trailing: _Menu<MediaKeys>(
                      value: s.mediaKeys,
                      onChanged: radio.setMediaKeys,
                      items: {
                        for (final mode in MediaKeys.values) mode: mode.label,
                      },
                    ),
                  ),
                  _Setting(
                    title: 'Seek scan',
                    subtitle: switch (s.seekScan) {
                      SeekScan.fm => 'Hold seek to stop on the next FM station',
                      SeekScan.hd => 'Hold seek to stop on the next HD station',
                    },
                    trailing: _Menu<SeekScan>(
                      value: s.seekScan,
                      onChanged: radio.setSeekScan,
                      items: const {SeekScan.fm: 'FM', SeekScan.hd: 'HD only'},
                    ),
                  ),

                  const _Section('Presets'),
                  _SliderSetting(
                    title: 'Preset bank',
                    subtitle:
                        '${presetPageCount(s.presetCount, s.presetsPerPage)} pages',
                    value: '${s.presetCount}',
                    onReset: s.presetCount == presetCountDefault
                        ? null
                        : () => radio.setPresetCount(presetCountDefault),
                    slider: Slider(
                      min: presetCountMin.toDouble(),
                      max: presetCountMax.toDouble(),
                      divisions: presetCountMax - presetCountMin,
                      value: s.presetCount.toDouble(),
                      onChanged: (v) => radio.setPresetCount(v.round()),
                    ),
                  ),
                  _Setting(
                    title: 'Presets per page',
                    trailing: _Menu<int>(
                      value: s.presetsPerPage,
                      onChanged: radio.setPresetsPerPage,
                      items: {
                        for (
                          var n = presetsPerPageMin;
                          n <= presetsPerPageMax;
                          n++
                        )
                          n: '$n',
                      },
                    ),
                  ),
                  _SliderSetting(
                    title: 'Preset size',
                    value: _percent(s.presetScale),
                    onReset: s.presetScale == 1
                        ? null
                        : () => radio.setPresetScale(1),
                    slider: Slider(
                      min: presetScaleMin,
                      max: presetScaleMax,
                      divisions: ((presetScaleMax - presetScaleMin) / 0.05)
                          .round(),
                      value: s.presetScale,
                      onChanged: radio.setPresetScale,
                    ),
                  ),
                  _Setting(
                    title: 'Preset arrows',
                    trailing: _Menu<PresetArrows>(
                      value: s.presetArrows,
                      onChanged: radio.setPresetArrows,
                      items: {
                        for (final mode in PresetArrows.values)
                          mode: mode.label,
                      },
                    ),
                  ),

                  const _Section('Audio'),
                  _SliderSetting(
                    title: 'Master Volume',
                    value: _percent(s.volume.clamp(0.0, 1.0)),
                    slider: Slider(
                      value: s.volume.clamp(0.0, 1.0).toDouble(),
                      onChanged: radio.setVolume,
                    ),
                  ),
                  _Setting(
                    title: 'Playback',
                    subtitle: switch (s.audioMode) {
                      AudioMode.auto =>
                        'HD when it decodes, FM when it drops out',
                      AudioMode.digital => 'Silent without an HD signal',
                      AudioMode.analog => 'Ignores HD',
                    },
                    trailing: _Menu<AudioMode>(
                      value: s.audioMode,
                      onChanged: radio.setAudioMode,
                      items: const {
                        AudioMode.auto: 'Auto',
                        AudioMode.digital: 'HD only',
                        AudioMode.analog: 'FM only',
                      },
                    ),
                  ),
                  _SliderSetting(
                    title: 'HD volume',
                    subtitle: 'Raise if HD sounds quieter than FM',
                    value: _percent(s.hdVolume),
                    onReset: s.hdVolume == 1
                        ? null
                        : () => radio.setHdVolume(1),
                    resetTooltip: 'Match FM',
                    slider: Slider(
                      min: hdVolumeMin,
                      max: hdVolumeMax,
                      divisions: ((hdVolumeMax - hdVolumeMin) / 0.05).round(),
                      value: s.hdVolume
                          .clamp(hdVolumeMin, hdVolumeMax)
                          .toDouble(),
                      onChanged: radio.setHdVolume,
                    ),
                  ),
                  _SliderSetting(
                    title: 'FM squelch',
                    subtitle: 'Mutes FM when the signal is weak',
                    value: s.squelchDb < 0 ? 'Off' : '${s.squelchDb} dB',
                    onReset: s.squelchDb == defaultSquelchDb
                        ? null
                        : () => radio.setSquelchDb(defaultSquelchDb),
                    resetTooltip: 'Reset squelch',
                    slider: Slider(
                      min: squelchOffDb.toDouble(),
                      max: squelchMaxDb.toDouble(),
                      divisions: squelchMaxDb - squelchOffDb,
                      value: s.squelchDb
                          .clamp(squelchOffDb, squelchMaxDb)
                          .toDouble(),
                      onChanged: (v) => radio.setSquelchDb(v.round()),
                    ),
                  ),

                  const _Section('Display'),
                  _SliderSetting(
                    title: 'Station size',
                    value: s.stationScale >= stationScaleMax
                        ? 'Fill'
                        : _percent(s.stationScale),
                    slider: Slider(
                      min: stationScaleMin,
                      max: stationScaleMax,
                      divisions: ((stationScaleMax - stationScaleMin) / 0.05)
                          .round(),
                      value: s.stationScale,
                      onChanged: radio.setStationScale,
                    ),
                  ),
                  _Setting(
                    title: 'Download station logos',
                    trailing: Switch(
                      value: s.downloadLogos,
                      onChanged: radio.setDownloadLogos,
                    ),
                  ),
                  _Setting(
                    title: 'Theme',
                    trailing: _Menu<AppTheme>(
                      value: s.theme,
                      onChanged: radio.setTheme,
                      items: const {
                        AppTheme.system: 'System',
                        AppTheme.light: 'Light',
                        AppTheme.dark: 'Dark',
                      },
                    ),
                  ),
                  _DisplaySize(scale: s.uiScale),

                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('Advanced'),
                    subtitle: const Text(
                      'Tuner gain, calibration, and logging',
                    ),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    childrenPadding: EdgeInsets.zero,
                    children: [
                      _Setting(
                        title: 'Gain',
                        subtitle: switch (s.gainMode) {
                          GainMode.auto => 'Picks the gain that decodes best',
                          GainMode.manual => 'Fixed gain',
                          GainMode.hardware => 'The tuner’s built-in AGC',
                        },
                        trailing: _Menu<GainMode>(
                          value: s.gainMode,
                          onChanged: radio.setGain,
                          items: const {
                            GainMode.auto: 'Smart',
                            GainMode.manual: 'Manual',
                            GainMode.hardware: 'Tuner',
                          },
                        ),
                      ),
                      if (s.gainMode == GainMode.manual)
                        _SliderSetting(
                          title: 'Manual gain',
                          value:
                              '${(s.manualGainTenthDb / 10).toStringAsFixed(1)} dB',
                          slider: gains.length > 1
                              ? Slider(
                                  max: (gains.length - 1).toDouble(),
                                  divisions: gains.length - 1,
                                  value: _nearestIndex(
                                    gains,
                                    s.manualGainTenthDb,
                                  ).toDouble(),
                                  onChanged: (v) => radio.setGain(
                                    GainMode.manual,
                                    manualTenthDb: gains[v.round()],
                                  ),
                                )
                              : Slider(
                                  max: 500,
                                  divisions: 50,
                                  value: s.manualGainTenthDb
                                      .clamp(0, 500)
                                      .toDouble(),
                                  onChanged: (v) => radio.setGain(
                                    GainMode.manual,
                                    manualTenthDb: v.round(),
                                  ),
                                ),
                        ),
                      _Setting(
                        title: 'Frequency correction',
                        subtitle: 'Crystal error, ppm',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Lower',
                              icon: const Icon(Icons.remove),
                              onPressed: () => radio.setPpm(s.ppm - 1),
                            ),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${s.ppm}',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Raise',
                              icon: const Icon(Icons.add),
                              onPressed: () => radio.setPpm(s.ppm + 1),
                            ),
                          ],
                        ),
                      ),
                      _Setting(
                        title: 'Bias tee',
                        subtitle: biasTeeSupported
                            ? 'Powers an active antenna'
                            : 'Not supported by this tuner',
                        trailing: Switch(
                          value: s.biasTee,
                          onChanged: biasTeeSupported ? radio.setBiasTee : null,
                        ),
                      ),
                      _SliderSetting(
                        title: 'HD / FM blend delay',
                        subtitle: 'Adjust if blends echo or skip',
                        value: '${s.blendAlignmentMs} ms',
                        onReset: s.blendAlignmentMs == _defaultBlendAlignmentMs
                            ? null
                            : () => radio.setBlendAlignmentMs(
                                _defaultBlendAlignmentMs,
                              ),
                        slider: Slider(
                          min: -2000,
                          max: 5000,
                          divisions: 140,
                          value: s.blendAlignmentMs
                              .clamp(-2000, 5000)
                              .toDouble(),
                          onChanged: (v) =>
                              radio.setBlendAlignmentMs(v.round()),
                        ),
                      ),
                      _Setting(
                        title: 'Log detail',
                        trailing: _Menu<LogDetail>(
                          value: effectiveLogDetail(s.logLevel),
                          onChanged: radio.setLogLevel,
                          items: {
                            for (final level in LogDetail.values)
                              level: level.label,
                          },
                        ),
                      ),
                    ],
                  ),

                  const _Section('Diagnostics'),
                  _Setting(
                    title: 'Diagnostics',
                    subtitle: 'Signal, audio, and the log',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DiagnosticsPage(),
                      ),
                    ),
                  ),

                  const _Section('About'),
                  _Setting(
                    title: 'Terra FM',
                    subtitle: '${radio.engine.version} · GPL-3.0-or-later',
                    trailing: TextButton(
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: 'Terra FM',
                        applicationVersion: radio.engine.version,
                        applicationLegalese: 'GPL-3.0-or-later.',
                      ),
                      child: const Text('Licenses'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static int _nearestIndex(List<int> gains, int value) {
    var best = 0;
    for (var i = 1; i < gains.length; i++) {
      if ((gains[i] - value).abs() < (gains[best] - value).abs()) best = i;
    }
    return best;
  }
}

/// Automatic or fixed UI scale. The slider applies on release: rescaling the
/// app mid-drag would move the slider under the finger.
class _DisplaySize extends StatefulWidget {
  const _DisplaySize({required this.scale});
  final double? scale;

  @override
  State<_DisplaySize> createState() => _DisplaySizeState();
}

class _DisplaySizeState extends State<_DisplaySize> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final radio = context.radio;
    final info = UiScale.of(context);
    final auto = widget.scale == null;
    final shown = _dragging ?? widget.scale ?? info.automatic;
    if (auto) {
      return _Setting(
        title: 'Display size',
        subtitle: 'Automatic (${_percent(info.automatic)})',
        trailing: Switch(
          value: true,
          onChanged: (_) => radio.setUiScale(info.scale),
        ),
      );
    }
    return _SliderSetting(
      title: 'Display size',
      value: _percent(shown),
      trailing: Switch(value: false, onChanged: (_) => radio.setUiScale(null)),
      slider: Slider(
        min: UiScale.minScale,
        max: UiScale.maxScale,
        divisions: ((UiScale.maxScale - UiScale.minScale) / 0.05).round(),
        value: shown.clamp(UiScale.minScale, UiScale.maxScale),
        onChanged: (v) => setState(() => _dragging = v),
        onChangeEnd: (v) {
          setState(() => _dragging = null);
          radio.setUiScale((v * 20).round() / 20);
        },
      ),
    );
  }
}

/// One setting: its name, an optional short note, and the control on the same line.
class _Setting extends StatelessWidget {
  const _Setting({
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: _Row(
        child: Row(
          children: [
            Expanded(
              child: _Label(title: title, subtitle: subtitle),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A slider with its value on the title line. Reset appears only once the
/// value has been changed.
class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.title,
    required this.value,
    required this.slider,
    this.subtitle,
    this.onReset,
    this.resetTooltip = 'Reset',
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String value;
  final Widget slider;
  final VoidCallback? onReset;
  final String resetTooltip;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Row(
      bottom: 0,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _Label(title: title, subtitle: subtitle),
              ),
              if (onReset != null)
                IconButton(
                  tooltip: resetTooltip,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.restart_alt, size: 20),
                  onPressed: onReset,
                ),
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8),
                child: Text(
                  value,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyLarge),
        if (subtitle != null)
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Row padding and the hairline between settings.
class _Row extends StatelessWidget {
  const _Row({required this.child, this.bottom = 12});
  final Widget child;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant
                .withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 8, bottom),
        child: child,
      ),
    );
  }
}

/// A compact menu that stays on its label's line.
class _Menu<T> extends StatelessWidget {
  const _Menu({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DropdownButton<T>(
        value: value,
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
