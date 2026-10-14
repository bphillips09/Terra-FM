import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../engine/radio_types.dart';
import '../radio/band_plan.dart';
import '../radio/program_type.dart';
import '../radio/radio_controller.dart';
import '../settings/settings.dart';
import 'widgets/preset_logo.dart';
import 'widgets/radio_select.dart';
import 'widgets/signal_bars.dart';
import 'widgets/station_art.dart';
import 'widgets/ui_scale.dart';

/// Everything needed while listening, on one screen without scrolling.
///
/// Frequency, signal, and the FM/HD buttons run across the top. The cover and
/// station fill the middle, centered. Fifteen preset slots sit along the
/// bottom, five at a time. Type and controls are the same size as the rest of
/// the app and only grow on large displays.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final system = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      0.85,
      1.3,
    );
    return RadioSelect(
      select: (r) => (
        r.settings.stationScale,
        r.settings.presetScale,
        r.settings.presetArrows,
        r.settings.presetsPerPage,
      ),
      builder: (context, v) {
        final (stationScale, presetScale, arrows, perPage) = v;
        return SafeArea(
          child: Theme(
            data: Theme.of(context)
                .copyWith(visualDensity: VisualDensity.standard),
            child: LayoutBuilder(
              builder: (context, c) {
                if (!c.hasBoundedWidth ||
                    !c.hasBoundedHeight ||
                    c.biggest.isEmpty) {
                  return const SizedBox.shrink();
                }
                final unit = _pageUnit(c.biggest);
                final tile = _tileHeight(c.biggest, unit, presetScale, perPage);
                // One orientation for the whole page: the header and the
                // station must not disagree about which way the screen is.
                final portrait = c.maxHeight > c.maxWidth;
                return _Scaled(
                  unit: unit,
                  system: system,
                  child: CustomMultiChildLayout(
                    delegate: _ListenLayout(
                      unit: unit,
                      portrait: portrait,
                      stationScale: stationScale,
                      dockHeight: _PresetDock.heightFor(tile, unit),
                    ),
                    children: [
                      LayoutId(
                        id: _Slot.header,
                        child: _Header(portrait: portrait),
                      ),
                      LayoutId(
                        id: _Slot.station,
                        child: _Station(
                          scale: stationScale,
                          portrait: portrait,
                        ),
                      ),
                      LayoutId(
                        id: _Slot.dock,
                        child: _PresetDock(tileHeight: tile, arrows: arrows),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Listen's spacing at unit 1. Every gap on the page is one of these.
abstract final class _Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
}

/// The settings and stations column (840) less Listen's side margins.
const _column = 840.0 - 2 * _Space.xl;

/// 1 on ordinary windows, so Listen matches the rest of the app. Large
/// displays grow the whole page together.
double _pageUnit(Size size) =>
    math.min(size.width / 1200, size.height / 760).clamp(1.0, 1.6).toDouble();

/// Finger-sized, scaled with the page and the preset-size setting, and kept
/// from swallowing a short window or towering over a narrow slot.
double _tileHeight(Size size, double unit, double presetScale, int perPage) {
  final slot = (size.width - 2 * _Space.xl * unit) / perPage;
  final cap = math.max(56.0, math.min(size.height * 0.24, slot * 1.1));
  return (72 * unit * presetScale).clamp(56.0, cap).toDouble();
}

/// The page's size unit, read by everything on Listen.
class _Unit extends InheritedWidget {
  const _Unit({required this.value, required super.child});
  final double value;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Unit>()!.value;

  @override
  bool updateShouldNotify(_Unit oldWidget) => value != oldWidget.value;
}

/// Sets the unit for [child] and scales its text by the same amount.
class _Scaled extends StatelessWidget {
  const _Scaled({
    required this.unit,
    required this.system,
    required this.child,
  });
  final double unit;
  final double system;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _Unit(
      value: unit,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(unit * system)),
        child: child,
      ),
    );
  }
}

/// Touch targets never get smaller than this, whatever the unit.
double _tap(double size) => math.max(40, size);

enum _Slot { header, station, dock }

/// Header at the top, presets at the bottom, the station centered in what is
/// left. The preset row is as wide as the station group, and never narrower
/// than the column the other pages use.
class _ListenLayout extends MultiChildLayoutDelegate {
  _ListenLayout({
    required this.unit,
    required this.portrait,
    required this.stationScale,
    required this.dockHeight,
  });

  final double unit;
  final bool portrait;
  final double stationScale;
  final double dockHeight;

  @override
  void performLayout(Size size) {
    final margin = _Space.xl * unit;
    final gap = _Space.l * unit;
    final width = math.max(0.0, size.width - 2 * margin);
    final header = layoutChild(
      _Slot.header,
      BoxConstraints(maxWidth: math.min(width, _column * unit)),
    );
    final stationTop = gap + header.height + gap;
    final area = Size(
      width,
      math.max(0.0, size.height - stationTop - gap - dockHeight - gap),
    );
    layoutChild(_Slot.station, BoxConstraints.tight(area));
    final group = _StationGeometry.of(
      area,
      unit,
      stationScale,
      portrait: portrait,
    ).width;
    final dockWidth = math.min(width, math.max(_column * unit, group));
    layoutChild(_Slot.dock, BoxConstraints.tight(Size(dockWidth, dockHeight)));
    positionChild(_Slot.header, Offset((size.width - header.width) / 2, gap));
    positionChild(_Slot.station, Offset(margin, stationTop));
    positionChild(
      _Slot.dock,
      Offset((size.width - dockWidth) / 2, size.height - gap - dockHeight),
    );
  }

  @override
  bool shouldRelayout(_ListenLayout oldDelegate) =>
      unit != oldDelegate.unit ||
      portrait != oldDelegate.portrait ||
      stationScale != oldDelegate.stationScale ||
      dockHeight != oldDelegate.dockHeight;
}

/// Cover and text column for the station area: side by side on a landscape
/// page, stacked on a portrait one. The page decides rather than the space
/// left over, which can be wide on a tall screen once the header and presets
/// take their share. The cover is never wider than the text column, so the
/// artwork does not outweigh the station it belongs to.
class _StationGeometry {
  const _StationGeometry._({
    required this.wide,
    required this.art,
    required this.column,
    required this.gap,
  });

  factory _StationGeometry.of(
    Size area,
    double u,
    double scale, {
    required bool portrait,
  }) {
    final besideGap = _Space.xl * u;
    final columnMin = 260 * u, columnMax = 380 * u;
    // A landscape window too narrow for a text column beside any cover still
    // stacks: nothing else fits.
    if (!portrait && area.width >= 480 * u) {
      final beside = math.max(
        0.0,
        math.min(
          math.min(area.height, columnMax),
          area.width - besideGap - columnMin,
        ),
      );
      final art = beside * scale;
      return _StationGeometry._(
        wide: true,
        art: art,
        column: math.min(
          columnMax,
          math.max(0.0, area.width - besideGap - art),
        ),
        gap: besideGap,
      );
    }
    final above = math.max(
      0.0,
      math.min(math.min(area.width, columnMax), area.height - _stackedText * u),
    );
    return _StationGeometry._(
      wide: false,
      art: above * scale,
      column: math.min(area.width, 560 * u),
      gap: _Space.l * u,
    );
  }

  /// Room under a stacked cover for the name, track, and transport.
  static const _stackedText = 192.0;

  final bool wide;
  final double art;
  final double column;
  final double gap;

  double get width => wide ? art + gap + column : column;
}

class _Station extends StatelessWidget {
  const _Station({required this.scale, required this.portrait});
  final double scale;
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final g = _StationGeometry.of(c.biggest, u, scale, portrait: portrait);
        final cover = SizedBox.square(
          dimension: g.art,
          child: const _ArtPanel(),
        );
        if (g.wide) {
          return Center(
            child: SizedBox(
              width: g.width,
              child: Row(
                children: [
                  cover,
                  SizedBox(width: g.gap),
                  SizedBox(
                    width: g.column,
                    child: const _TextColumn(center: false),
                  ),
                ],
              ),
            ),
          );
        }
        return Center(
          child: SizedBox(
            width: g.column,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                cover,
                SizedBox(height: g.gap),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(0.0, c.maxHeight - g.art - g.gap),
                  ),
                  child: const _TextColumn(center: true),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Station name and track, then the transport. Titles and radio text wrap
/// onto more lines when there is room. On a short window the block scales
/// down so none of it is clipped. The transport keeps its size.
class _TextColumn extends StatelessWidget {
  const _TextColumn({required this.center});
  final bool center;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final transport = math.min(_Transport.heightFor(u), c.maxHeight);
        final gap = (c.maxHeight - transport)
            .clamp(0.0, _Space.l * u)
            .toDouble();
        final text = math.max(0.0, c.maxHeight - transport - gap);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: text),
              child: ShrinkToFit(
                alignment: center ? Alignment.topCenter : Alignment.centerLeft,
                child: _Details(center: center),
              ),
            ),
            SizedBox(height: gap),
            SizedBox(
              height: transport,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: center ? Alignment.center : Alignment.centerLeft,
                child: const _Transport(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Frequency and signal, then the FM/HD buttons: side by side on a landscape
/// screen, stacked on a portrait one. The shape is the same whatever is known
/// about the station, so tuning and HD lock change what the header shows
/// without moving anything.
class _Header extends StatelessWidget {
  const _Header({required this.portrait});
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _AlertBanner(),
        if (portrait) ...[
          const _FrequencyLine(),
          SizedBox(height: _Space.s * u),
          const _SourceChips(alignment: Alignment.center),
        ] else
          // Halves meeting at the center: the frequency stays put while
          // buttons are added to its right.
          Row(
            children: [
              const Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  heightFactor: 1,
                  child: _FrequencyLine(),
                ),
              ),
              SizedBox(width: _Space.xl * u),
              const Expanded(
                child: _SourceChips(alignment: Alignment.centerLeft),
              ),
            ],
          ),
      ],
    );
  }
}

/// An HD emergency alert, across the top of the page while it lasts. Short
/// screens get one line; tapping shows the whole message.
class _AlertBanner extends StatelessWidget {
  const _AlertBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final u = _Unit.of(context);
    final short = MediaQuery.sizeOf(context).height < 560;
    return RadioSelect(
      select: (r) => r.state.hd.alert,
      builder: (context, alert) {
        if (alert == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(bottom: _Space.l * u),
          child: Material(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(_Space.m * u),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  icon: const Icon(Icons.warning_amber),
                  title: const Text('Emergency alert'),
                  content: Text(alert),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _Space.l * u,
                  vertical: _Space.s * u,
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, color: scheme.onErrorContainer),
                    SizedBox(width: _Space.m * u),
                    Expanded(
                      child: Text(
                        alert,
                        maxLines: short ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArtPanel extends StatelessWidget {
  const _ArtPanel();

  @override
  Widget build(BuildContext context) {
    return RadioSelect(
      select: (r) => (
        r.state.hd.artFor(r.state.program)?.bytes,
        r.state.hd.logoFor(r.state.program)?.bytes ?? r.cachedLogo,
        r.state.frequencyHz,
        r.state.hdWaitCaption(audioOn: r.audioEnabled),
      ),
      builder: (context, v) {
        final (art, logo, f, waiting) = v;
        return StationArt(
          art: art,
          logo: logo,
          fallbackLabel: f == null ? 'FM' : formatMhz(f),
          status: waiting,
        );
      },
    );
  }
}

/// Station name and what is playing, beside or under the cover.
class _Details extends StatelessWidget {
  const _Details({required this.center});
  final bool center;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        _StationTitle(center: center),
        SizedBox(height: _Space.s * u),
        _TrackInfo(center: center),
      ],
    );
  }
}

/// Big frequency readout (tap to type a frequency) with reception status.
class _FrequencyLine extends StatelessWidget {
  const _FrequencyLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final u = _Unit.of(context);
    final digits = theme.textTheme.displaySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w600,
    );
    return RadioSelect(
      select: (r) =>
          (r.state.frequencyHz ?? r.settings.lastFrequencyHz, r.seeking),
      builder: (context, v) {
        final (f, seeking) = v;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(_Space.m * u),
                    onTap: () => _enterFrequency(context),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          // As wide as 107.9 whatever is tuned, so MHz and the
                          // badges beside it stay put.
                          _Reserve(
                            widest: Text('000.0', style: digits),
                            alignment: Alignment.centerRight,
                            child: Text(
                              f == null ? '--.-' : formatMhz(f),
                              style: digits,
                            ),
                          ),
                          SizedBox(width: _Space.xs * u),
                          Text('MHz', style: theme.textTheme.titleMedium),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(width: _Space.m * u),
                const _ReceptionStatus(),
              ],
            ),
            SizedBox(
              height: 2 * u,
              width: 120 * u,
              child: seeking ? LinearProgressIndicator(minHeight: 2 * u) : null,
            ),
          ],
        );
      },
    );
  }

  Future<void> _enterFrequency(BuildContext context) async {
    final radio = context.radio;
    final controller = TextEditingController(
      text: radio.state.frequencyHz == null
          ? ''
          : formatMhz(radio.state.frequencyHz!),
    );
    final mhz = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tune to'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(suffixText: 'MHz'),
          onSubmitted: (s) => Navigator.pop(context, double.tryParse(s)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: const Text('Tune'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (mhz == null) return;
    final hz = (mhz * 1e6).round();
    if (hz < 24000000 || hz > 1766000000) return;
    radio.tune(radio.band.contains(hz) ? radio.band.snap(hz) : hz);
  }
}

/// How strong the signal is and what is audible: the bars, then one badge
/// (HD, FM STEREO, FM, or LOADING while HD is selected but silent) in a slot
/// as wide as the widest. Laid out even before streaming, so nothing moves
/// when it starts.
class _ReceptionStatus extends StatelessWidget {
  const _ReceptionStatus();

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return RadioSelect(
      select: (r) => (
        r.state.isStreaming,
        r.state.audible,
        r.state.hd.isHdStation,
        r.state.hd.synced,
        (r.state.hd.merDb ?? -99).round(),
        (r.state.fm.status?.cnrDb ?? -99).round(),
        r.state.fm.status?.stereo ?? false,
        r.state.hdWaitCaption(audioOn: r.audioEnabled),
      ),
      builder: (context, v) {
        final (streaming, audible, isHd, synced, mer, cnr, stereo, waiting) = v;
        final scheme = Theme.of(context).colorScheme;
        final quality = synced
            ? SignalBars.fromMer(mer.toDouble())
            : SignalBars.fromCnr(cnr.toDouble());
        final badge = switch (audible) {
          AudioSource.hd => _Badge('HD', scheme.primary, scheme.onPrimary),
          AudioSource.analog => _Badge(
            stereo ? 'FM STEREO' : 'FM',
            scheme.secondary,
            scheme.onSecondary,
          ),
          AudioSource.none => _Badge(
            waiting != null ? 'LOADING' : (isHd ? 'HD…' : 'FM'),
            scheme.outline,
            scheme.surface,
            outlined: true,
          ),
        };
        return Visibility(
          visible: streaming,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: _Space.s * u,
            children: [
              SignalBars(quality: quality, size: 18 * u),
              _Reserve(
                widest: _Badge(
                  'FM STEREO',
                  scheme.secondary,
                  scheme.onSecondary,
                ),
                alignment: Alignment.centerLeft,
                child: badge,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(
    this.text,
    this.background,
    this.foreground, {
    this.outlined = false,
  });
  final String text;
  final Color background;
  final Color foreground;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    final style = TextStyle(
      color: outlined ? background : foreground,
      fontWeight: FontWeight.w800,
      fontSize: 11,
      height: 1.4,
      letterSpacing: 0.8,
    );
    return Container(
      padding: EdgeInsets.symmetric(horizontal: _Space.s * u, vertical: 2 * u),
      // Filled badges get a border too: it adds to the size, and outlined and
      // filled badges must match.
      decoration: BoxDecoration(
        color: outlined ? null : background,
        border: Border.all(color: background),
        borderRadius: BorderRadius.circular(6 * u),
      ),
      child: Text(text, style: style),
    );
  }
}

/// Lays out [child] in the space [widest] would take, so content that changes
/// size does not resize or shift what is around it.
class _Reserve extends StatelessWidget {
  const _Reserve({
    required this.widest,
    required this.child,
    this.alignment = Alignment.center,
  });
  final Widget widest;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: alignment,
      children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: widest,
        ),
        child,
      ],
    );
  }
}

/// Station name, then its program category and slogan.
class _StationTitle extends StatelessWidget {
  const _StationTitle({required this.center});
  final bool center;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final align = center ? TextAlign.center : TextAlign.start;
    return RadioSelect(
      select: (r) => (
        r.state.stationName,
        r.state.hd.slogan,
        programCategory(r.state, r.band),
      ),
      builder: (context, v) {
        final (name, slogan, category) = v;
        final tagline = slogan != null && slogan != name ? slogan : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Text(
              name ?? 'Terra FM',
              textAlign: align,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  if (category != null)
                    TextSpan(
                      text: category,
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (category != null && tagline != null)
                    const TextSpan(text: '  ·  '),
                  TextSpan(text: tagline ?? (category == null ? ' ' : null)),
                ],
              ),
              textAlign: align,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// FM and each HD program; the selection lasts until the next tune. FM is
/// always there while streaming, and HD programs are added beside it as they
/// are found, so the row keeps its place and height.
class _SourceChips extends StatelessWidget {
  const _SourceChips({required this.alignment});
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final u = _Unit.of(context);
    return RadioSelect(
      select: (r) => (
        r.state.isStreaming,
        r.state.hd.isHdStation,
        r.state.hd.programs,
        r.state.program,
        r.state.audioMode,
        r.state.hdWaitCaption(audioOn: r.audioEnabled),
      ),
      builder: (context, v) {
        final (streaming, isHd, programs, program, audioMode, waiting) = v;
        final radio = context.radio;
        final slots = programs.keys.toList();
        if ((isHd || programs.isNotEmpty || program > 0) && slots.isEmpty) {
          slots.add(program);
        }
        if (program > 0 && !slots.contains(program)) slots.add(program);
        slots.sort();
        final hd = slots.isNotEmpty;
        // Scaled down rather than clipped: a sliced chip looks broken, and
        // eight HD programs still have to fit on a phone.
        return Align(
          alignment: alignment,
          heightFactor: 1,
          child: Visibility(
            visible: streaming,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: alignment,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: _Space.s * u,
                children: [
                  _SourceChip(
                    label: 'FM',
                    tooltip: 'Analog FM',
                    selected: audioMode == AudioMode.analog || !hd,
                    onPressed: () => radio.selectAudioSource(null),
                  ),
                  if (hd)
                    for (final p in slots)
                      _SourceChip(
                        label: programs[p]?.label ?? 'HD${p + 1}',
                        tooltip:
                            audioMode != AudioMode.analog &&
                                p == program &&
                                waiting != null
                            ? waiting
                            : ((programs[p]?.programType ?? 0) > 0
                                  ? programs[p]?.typeName
                                  : null),
                        selected: audioMode != AudioMode.analog && p == program,
                        onPressed: () => radio.selectAudioSource(p),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.tooltip,
  });
  final String label;
  final String? tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final u = _Unit.of(context);
    final chip = Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_Space.m * u),
          side: BorderSide(
            color: selected ? scheme.secondaryContainer : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _Space.l * u,
              vertical: 10 * u,
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.center});
  final bool center;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final align = center ? TextAlign.center : TextAlign.start;
    return RadioSelect(
      select: (r) => r.state.nowPlaying,
      builder: (context, track) {
        final artistLine = [
          track?.artist,
          track?.album,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' — ');
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Text(
              track?.title ?? ' ',
              textAlign: align,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              artistLine.isEmpty ? ' ' : artistLine,
              textAlign: align,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Seek and step around a central play button. Tap seek for the next scanned
/// station. Hold seek to scan the band.
class _Transport extends StatelessWidget {
  const _Transport();

  /// Buttons stop growing before the type does.
  static double _buttonUnit(double unit) => math.min(unit, 1.45);

  static double heightFor(double unit) => _tap(56 * _buttonUnit(unit));

  @override
  Widget build(BuildContext context) {
    final u = _buttonUnit(_Unit.of(context));
    final side = _tap(48 * u);
    final play = heightFor(_Unit.of(context));
    ButtonStyle style(double size) => IconButton.styleFrom(
      minimumSize: Size.square(size),
      maximumSize: Size.square(size),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    Widget button(
      String tooltip,
      IconData icon,
      VoidCallback onPressed, {
      VoidCallback? onLongPress,
    }) => IconButton(
      tooltip: tooltip,
      iconSize: 28 * u,
      style: style(side),
      icon: Icon(icon),
      onPressed: onPressed,
      onLongPress: onLongPress,
    );
    return RadioSelect(
      select: (r) => (r.state.isStreaming, r.audioEnabled, r.settings.seekScan),
      builder: (context, v) {
        final (streaming, audioOn, seekScan) = v;
        final radio = context.radio;
        final playing = streaming && audioOn;
        final hold = seekScan == SeekScan.hd ? 'HD' : 'FM';
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: _Space.s * u,
          children: [
            button(
              'Seek down. Hold to scan for $hold',
              Icons.fast_rewind,
              () => radio.seek(-1),
              onLongPress: () => radio.scanSeek(-1),
            ),
            button(
              'Step down',
              Icons.chevron_left,
              () => radio.stepChannel(-1),
            ),
            const SizedBox.shrink(),
            IconButton.filled(
              iconSize: 32 * u,
              style: style(play),
              tooltip: playing ? 'Mute' : 'Play',
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: () async {
                if (!streaming) await radio.connectPreferred();
                radio.setAudioEnabled(!playing);
              },
            ),
            const SizedBox.shrink(),
            button('Step up', Icons.chevron_right, () => radio.stepChannel(1)),
            button(
              'Seek up. Hold to scan for $hold',
              Icons.fast_forward,
              () => radio.seek(1),
              onLongPress: () => radio.scanSeek(1),
            ),
          ],
        );
      },
    );
  }
}

/// Fifteen preset slots along the bottom, five at a time, looping in both
/// directions. Tap one to tune. Press and hold to save the current station
/// there, or to replace it.
class _PresetDock extends StatefulWidget {
  const _PresetDock({required this.tileHeight, required this.arrows});

  final double tileHeight;
  final PresetArrows arrows;

  static const _dot = 6.0;

  static double heightFor(double tileHeight, double unit) =>
      tileHeight + (_Space.s + _dot) * unit;

  @override
  State<_PresetDock> createState() => _PresetDockState();
}

class _PresetDockState extends State<_PresetDock> {
  /// Divisible by every page count from 1 to 10, so the first page is page 0.
  static const _start = 252000;

  int _pages = presetCountDefault ~/ presetsPerPageDefault;
  int _perPage = presetsPerPageDefault;

  final _page = PageController(initialPage: _start);
  var _index = _start;
  var _wheel = 0.0;
  RadioController? _radio;
  int? _tunedHz;
  var _tunedProgram = 0;
  var _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final radio = context.radio;
    if (!identical(_radio, radio)) {
      _radio?.removeListener(_onRadio);
      _radio = radio;
      radio.addListener(_onRadio);
      _seeded = false;
    }
    if (!_seeded) {
      _seeded = true;
      _tunedHz = radio.state.frequencyHz;
      _tunedProgram = radio.state.program;
    }
  }

  @override
  void dispose() {
    _radio?.removeListener(_onRadio);
    _page.dispose();
    super.dispose();
  }

  /// After a tune, show the page that holds the matching preset. Swiping
  /// away stays put until the next tune.
  void _useLayout(int count, int perPage) {
    _perPage = perPage;
    _pages = presetPageCount(count, perPage);
  }

  void _onRadio() {
    final radio = _radio;
    if (radio == null) return;
    _useLayout(radio.settings.presetCount, radio.settings.presetsPerPage);
    final f = radio.state.frequencyHz;
    final program = radio.state.program;
    if (f == _tunedHz && program == _tunedProgram) return;
    _tunedHz = f;
    _tunedProgram = program;
    if (f == null) return;
    final index = radio.settings.slots.indexWhere(
      (p) => p?.matches(f, program) ?? false,
    );
    if (index < 0) return;
    _showPage(index ~/ _perPage);
  }

  void _showPage(int page) {
    final current = _index % _pages;
    if (page == current) return;
    var delta = page - current;
    if (delta > _pages ~/ 2) delta -= _pages;
    if (delta < -(_pages ~/ 2)) delta += _pages;
    if (delta == 0) return;
    final target = _index + delta;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_page.hasClients) return;
      if (_index % _pages == page) return;
      _page.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  void _go(int delta) {
    if (!_page.hasClients) return;
    _page.animateToPage(
      _index + delta,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wheel += delta;
      if (_wheel.abs() < 36) return;
      final dir = _wheel > 0 ? 1 : -1;
      _wheel = 0;
      _go(dir);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final u = _Unit.of(context);
    final height = widget.tileHeight;
    return RadioSelect(
      select: (r) => (
        r.settings.presets,
        r.settings.presetCount,
        r.settings.presetsPerPage,
        r.state.frequencyHz,
        r.state.program,
      ),
      builder: (context, v) {
        final (presets, count, perPage, f, program) = v;
        final radio = context.radio;
        final slots = presetSlots(presets, count);
        _useLayout(count, perPage);
        final current = _index % _pages;
        Widget arrow(String tooltip, IconData icon, int dir) => SizedBox(
          width: 40 * u,
          height: height,
          child: IconButton(
            tooltip: tooltip,
            iconSize: 28 * u,
            style: IconButton.styleFrom(
              minimumSize: Size(40 * u, height),
              maximumSize: Size(40 * u, height),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _go(dir),
            icon: Icon(icon),
          ),
        );

        return Column(
          children: [
            SizedBox(
              height: height,
              child: LayoutBuilder(
                builder: (context, c) {
                  // Auto leaves them out where they would crush the five
                  // presets; swiping is the control there.
                  final showArrows = switch (widget.arrows) {
                    PresetArrows.on => true,
                    PresetArrows.off => false,
                    PresetArrows.auto => c.maxWidth >= 560 * u,
                  };
                  return Row(
                    children: [
                      if (showArrows)
                        arrow('Previous presets', Icons.chevron_left, -1),
                      Expanded(
                        child: Listener(
                          onPointerSignal: _onWheel,
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              scrollbars: false,
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                                PointerDeviceKind.stylus,
                              },
                            ),
                            child: PageView.builder(
                              controller: _page,
                              onPageChanged: (i) => setState(() => _index = i),
                              itemBuilder: (context, i) => _PresetPage(
                                start: (i % _pages) * _perPage,
                                perPage: _perPage,
                                slots: slots,
                                frequencyHz: f,
                                program: program,
                                onTune: radio.tune,
                                onStore: f == null
                                    ? null
                                    : (n) {
                                        final existing = radio.storePreset(n);
                                        if (existing == null ||
                                            !context.mounted) {
                                          return;
                                        }
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Already saved as preset $existing',
                                            ),
                                          ),
                                        );
                                      },
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (showArrows)
                        arrow('Next presets', Icons.chevron_right, 1),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: _Space.s * u),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages; i++)
                  Container(
                    width: (i == current ? 16 : _PresetDock._dot) * u,
                    height: _PresetDock._dot * u,
                    margin: EdgeInsets.symmetric(horizontal: 3 * u),
                    decoration: BoxDecoration(
                      color: i == current
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(_PresetDock._dot * u),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PresetPage extends StatelessWidget {
  const _PresetPage({
    required this.start,
    required this.perPage,
    required this.slots,
    required this.frequencyHz,
    required this.program,
    required this.onTune,
    required this.onStore,
  });

  final int start;
  final int perPage;
  final List<Preset?> slots;
  final int? frequencyHz;
  final int program;
  final void Function(int frequencyHz, {int program}) onTune;
  final void Function(int index)? onStore;

  @override
  Widget build(BuildContext context) {
    final gap = _Space.s * _Unit.of(context);
    return Padding(
      // Half a gap at each edge, so neighbouring pages are a full gap apart
      // while swiping.
      padding: EdgeInsets.symmetric(horizontal: gap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: gap,
        children: [
          for (var n = 0; n < perPage; n++)
            if (start + n >= slots.length)
              const Expanded(child: SizedBox.expand())
            else
              Expanded(
                child: _PresetButton(
                  number: start + n + 1,
                  preset: slots[start + n],
                  selected:
                      slots[start + n]?.matches(frequencyHz ?? -1, program) ??
                      false,
                  onPressed: switch (slots[start + n]) {
                    final p? => () => onTune(p.frequencyHz, program: p.program),
                    null => null,
                  },
                  onLongPress: onStore == null
                      ? null
                      : () => onStore!(start + n),
                ),
              ),
        ],
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.number,
    required this.preset,
    required this.selected,
    required this.onPressed,
    required this.onLongPress,
  });

  final int number;
  final Preset? preset;
  final bool selected;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final u = _Unit.of(context);
    final saved = preset;
    final tooltip = saved == null
        ? 'Preset $number. Hold to save the current station'
        : 'Preset $number. Hold to replace';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Material(
          color: saved == null
              ? Colors.transparent
              : selected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_Space.m * u),
            side: BorderSide(
              color: saved == null
                  ? scheme.outlineVariant
                  : (selected ? scheme.secondary : Colors.transparent),
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            onLongPress: onLongPress,
            child: saved == null
                ? Center(
                    child: Text(
                      '$number',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _PresetContent(preset: saved),
          ),
        ),
      ),
    );
  }
}

/// Logo beside the name and channel, or, in a slot too narrow for that, the
/// logo over a one-line label.
class _PresetContent extends StatelessWidget {
  const _PresetContent({required this.preset});
  final Preset preset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final u = _Unit.of(context);
    final hd = preset.program > 0 ? ' HD${preset.program + 1}' : '';
    final channel = '${formatMhz(preset.frequencyHz)}$hd';
    final name = preset.name;
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 150 * u;
        final pad = (narrow ? _Space.s : _Space.m) * u;
        final label = 16 * u;
        final logo = narrow
            ? math.min(
                c.maxHeight - 2 * pad - _Space.xs * u - label,
                c.maxWidth - 2 * pad,
              )
            : math.min(c.maxHeight - 2 * pad, c.maxWidth * 0.4);
        final mark = PresetLogo(
          preset: preset,
          size: math.max(0.0, logo),
          placeholder: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(math.max(4.0, logo / 5)),
            ),
            child: Icon(
              Icons.radio,
              size: logo * 0.55,
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
        if (narrow) {
          return Padding(
            padding: EdgeInsets.all(pad),
            child: ShrinkToFit(
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  mark,
                  SizedBox(height: _Space.xs * u),
                  Text(
                    name == null ? channel : '$name$hd',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Row(
            children: [
              mark,
              SizedBox(width: pad),
              Expanded(
                child: ShrinkToFit(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name ?? channel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (name != null)
                        Text(
                          channel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
