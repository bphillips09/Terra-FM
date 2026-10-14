import 'dart:async';

import 'package:flutter/material.dart';

import '../radio/band_plan.dart';
import 'widgets/map_views.dart';
import 'widgets/radio_select.dart';

enum MapKind { traffic, weather }

/// Traffic and weather maps broadcast by the station (HERE Images / TTN).
class MapsPage extends StatefulWidget {
  const MapsPage({super.key, required this.kind, required this.onKindChanged});
  final MapKind kind;
  final ValueChanged<MapKind> onKindChanged;

  @override
  State<MapsPage> createState() => _MapsPageState();
}

class _MapsPageState extends State<MapsPage> {
  /// Shown radar frame; null follows the newest.
  int? _frame;
  Timer? _loop;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Keeps the "n min ago" text current.
    _clock = Timer.periodic(
      const Duration(seconds: 30),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _loop?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  void _togglePlay(int frameCount) {
    if (_loop != null) {
      setState(() {
        _loop!.cancel();
        _loop = null;
        _frame = null;
      });
      return;
    }
    var tick = 0;
    setState(() {
      _frame = 0;
      _loop = Timer.periodic(const Duration(milliseconds: 600), (_) {
        // Hold the newest frame a little longer before starting over.
        final cycle = frameCount + 2;
        tick = (tick + 1) % cycle;
        setState(() => _frame = tick.clamp(0, frameCount - 1));
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: RadioSelect(
        select: (r) =>
            (r.state.maps, r.state.hd.latitude, r.state.hd.longitude),
        builder: (context, v) {
          final (maps, lat, lon) = v;
          final marker = lat == null || lon == null ? null : (lat, lon);
          final frames = maps.weather;
          if (_loop != null && frames.length < 2) {
            _loop!.cancel();
            _loop = null;
            _frame = null;
          }
          final frameIndex = (_frame ?? frames.length - 1).clamp(
            0,
            frames.isEmpty ? 0 : frames.length - 1,
          );
          final now = DateTime.now();

          final String? status;
          final Widget body;
          switch (widget.kind) {
            case MapKind.traffic:
              final traffic = maps.traffic;
              final time = traffic?.time;
              status = traffic == null
                  ? null
                  : [
                      if (time != null)
                        'Updated ${formatAge(now.difference(time))}',
                      if (traffic.frequencyHz != null)
                        'from ${formatMhz(traffic.frequencyHz!)} MHz',
                    ].join(' · ');
              body = traffic == null
                  ? const _EmptyMap(
                      icon: Icons.traffic_outlined,
                      title: 'No traffic map yet',
                    )
                  : TrafficMapView(map: traffic);
            case MapKind.weather:
              final frame = frames.isEmpty ? null : frames[frameIndex];
              final time = frame?.time;
              status = frame == null
                  ? null
                  : [
                      if (time != null)
                        'Radar ${formatAge(now.difference(time))}',
                      if (frame.frequencyHz != null)
                        'from ${formatMhz(frame.frequencyHz!)} MHz',
                    ].join(' · ');
              body = frame == null
                  ? const _EmptyMap(
                      icon: Icons.cloud_outlined,
                      title: 'No weather radar yet',
                    )
                  : WeatherMapView(
                      frame: frame,
                      marker: marker,
                      showAttribution: true,
                    );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    SegmentedButton<MapKind>(
                      segments: const [
                        ButtonSegment(
                          value: MapKind.traffic,
                          label: Text('Traffic'),
                          icon: Icon(Icons.traffic),
                        ),
                        ButtonSegment(
                          value: MapKind.weather,
                          label: Text('Weather'),
                          icon: Icon(Icons.radar),
                        ),
                      ],
                      showSelectedIcon: false,
                      selected: {widget.kind},
                      onSelectionChanged: (k) => widget.onKindChanged(k.first),
                    ),
                    const SizedBox(width: 16),
                    if (status != null)
                      Expanded(
                        child: Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(child: body),
                if (widget.kind == MapKind.weather && frames.length > 1)
                  Row(
                    children: [
                      IconButton(
                        tooltip: _loop == null ? 'Play radar loop' : 'Stop',
                        icon: Icon(
                          _loop == null ? Icons.play_arrow : Icons.pause,
                        ),
                        onPressed: () => _togglePlay(frames.length),
                      ),
                      Expanded(
                        child: Slider(
                          max: (frames.length - 1).toDouble(),
                          divisions: frames.length - 1,
                          value: frameIndex.toDouble(),
                          onChanged: (v) => setState(() {
                            _loop?.cancel();
                            _loop = null;
                            final i = v.round();
                            _frame = i == frames.length - 1 ? null : i;
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          frames[frameIndex].time == null
                              ? ''
                              : formatMapTime(
                                  context,
                                  frames[frameIndex].time!,
                                ),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EmptyMap extends StatelessWidget {
  const _EmptyMap({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Traffic and weather maps take a few minutes to download. Only some channels are compatible.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
