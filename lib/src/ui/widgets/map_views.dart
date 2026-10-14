import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../maps/basemap.dart';
import '../../maps/geo.dart';
import '../../maps/map_state.dart';
import '../../maps/radar_image.dart';

/// "14:05" / "2:05 PM" in local time, per the device's 24-hour setting.
String formatMapTime(BuildContext context, DateTime time) => MaterialLocalizations.of(context).formatTimeOfDay(
  TimeOfDay.fromDateTime(time.toLocal()),
  alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
);

String formatAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// Small translucent label drawn over a map.
class MapBadge extends StatelessWidget {
  const MapBadge(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 4)],
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// The 3×3 traffic map; missing tiles show as placeholders.
class TrafficMapView extends StatelessWidget {
  const TrafficMapView({super.key, required this.map, this.showStatus = true});
  final TrafficMap map;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slots = map.tiles;
    final size = map.tiles.isEmpty ? null : pngSize(map.tiles.values.first.bytes);
    final aspect = size == null || size.$2 == 0 ? 1.0 : size.$1 / size.$2;
    final time = map.time;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var r = 0; r < 3; r++)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var c = 0; c < 3; c++)
                          Expanded(child: _Tile(tile: slots[r * TrafficMap.columns + c], placeholder: scheme.surfaceContainerHigh)),
                      ],
                    ),
                  ),
              ],
            ),
            if (showStatus)
              Positioned(
                right: 6,
                bottom: 6,
                child: MapBadge(
                  map.complete
                      ? (time == null ? 'Traffic' : formatMapTime(context, time))
                      : 'Receiving ${map.tiles.length}/${TrafficMap.tileCount}',
                  icon: Icons.traffic,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.placeholder});
  final TrafficTile? tile;
  final Color placeholder;

  @override
  Widget build(BuildContext context) {
    final t = tile;
    return ColoredBox(
      color: placeholder,
      child: t == null
          ? null
          : Image.memory(
              t.bytes,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const SizedBox.expand(),
            ),
    );
  }
}

/// A radar frame over the offline base map (when it needs one).
class WeatherMapView extends StatefulWidget {
  const WeatherMapView({
    super.key,
    required this.frame,
    this.marker,
    this.showStatus = true,
    this.showAttribution = false,
  });

  final WeatherFrame frame;

  /// Station location, drawn as a dot.
  final (double, double)? marker;
  final bool showStatus;
  final bool showAttribution;

  @override
  State<WeatherMapView> createState() => _WeatherMapViewState();
}

class _WeatherMapViewState extends State<WeatherMapView> {
  PreparedRadar? _radar;
  BaseMap? _baseMap;
  Object? _error;
  Uint8List? _loading;

  @override
  void initState() {
    super.initState();
    BaseMap.load().then((m) {
      if (mounted) setState(() => _baseMap = m);
    }, onError: (Object _) {});
    _prepare();
  }

  @override
  void didUpdateWidget(WeatherMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frame.bytes, widget.frame.bytes)) _prepare();
  }

  // Keeps showing the previous frame until the next one is ready, so radar
  // loops don't flicker.
  void _prepare() {
    final bytes = widget.frame.bytes;
    _loading = bytes;
    prepareRadar(bytes).then(
      (r) {
        if (!mounted || !identical(_loading, bytes)) return;
        setState(() {
          _radar = r;
          _error = null;
        });
      },
      onError: (Object e) {
        if (mounted && identical(_loading, bytes)) setState(() => _error = e);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radar = _radar;
    if (radar == null) {
      return Center(
        child: _error != null
            ? Icon(Icons.broken_image_outlined, color: theme.colorScheme.outline)
            : const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final bounds = widget.frame.bounds;
    final colors = BaseMapColors.forBrightness(theme.brightness, theme.colorScheme.primary);
    final baseMap = _baseMap;
    final time = widget.frame.time;
    return Center(
      child: AspectRatio(
        aspectRatio: radar.height == 0 ? 1 : radar.width / radar.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (radar.needsBaseMap)
              if (bounds != null && baseMap != null)
                RepaintBoundary(
                  child: CustomPaint(
                    painter: BaseMapPainter(
                      map: baseMap,
                      bounds: bounds,
                      colors: colors,
                      marker: widget.marker,
                      labelStyle: theme.textTheme.labelSmall ?? const TextStyle(),
                    ),
                  ),
                )
              else
                ColoredBox(color: colors.water),
            Image.memory(radar.bytes, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium),
            if (widget.showStatus && time != null)
              Positioned(right: 6, bottom: 6, child: MapBadge(formatMapTime(context, time), icon: Icons.radar)),
            if (widget.showAttribution && radar.needsBaseMap && bounds != null)
              Positioned(
                left: 6,
                bottom: 4,
                child: Text(
                  'Map: Natural Earth',
                  style: theme.textTheme.labelSmall?.copyWith(color: colors.label.withValues(alpha: 0.7)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
