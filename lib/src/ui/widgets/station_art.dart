import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Album art, station logo, or a generated placeholder. Corners and the
/// margin around a logo are proportional to the size.
class StationArt extends StatelessWidget {
  const StationArt({
    super.key,
    this.art,
    this.logo,
    required this.fallbackLabel,
    this.status,
  });

  final Uint8List? art;
  final Uint8List? logo;
  final String fallbackLabel;

  /// Shown across the bottom of the cover, for example while HD audio buffers.
  final String? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, c) {
          final side = c.biggest.shortestSide;
          final placeholder = _placeholder(scheme, side);
          final Widget child;
          if (art case final art?) {
            child = ColoredBox(
              color: Colors.black,
              child: Image.memory(
                art,
                key: ValueKey(art.hashCode),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
            );
          } else if (logo case final logo?) {
            child = _LogoTile(
              bytes: logo,
              padding: side * 0.08,
              placeholder: placeholder,
            );
          } else {
            child = placeholder;
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(side * 0.08),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                if (status case final status?)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _StatusBar(status),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme, double side) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(side * 0.14),
          child: FittedBox(
            child: Text(
              fallbackLabel,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
                fontSize: 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Spinner and a short status across the bottom of the cover.
class _StatusBar extends StatelessWidget {
  const _StatusBar(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.inverseSurface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onInverseSurface,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A logo on its own edge colour, so a logo with a solid background fills
/// the square seamlessly. Transparent logos sit on white, which is what they
/// are usually drawn for.
class _LogoTile extends StatefulWidget {
  const _LogoTile({
    required this.bytes,
    required this.padding,
    required this.placeholder,
  });
  final Uint8List bytes;
  final double padding;
  final Widget placeholder;

  @override
  State<_LogoTile> createState() => _LogoTileState();
}

class _LogoTileState extends State<_LogoTile> {
  static final _edges = Expando<Color>();
  Color? _edge;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_LogoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _resolve();
  }

  Future<void> _resolve() async {
    final bytes = widget.bytes;
    _edge = _edges[bytes];
    if (_edge != null) return;
    final color = await _edgeColor(bytes);
    if (color == null) return;
    _edges[bytes] = color;
    if (mounted && identical(widget.bytes, bytes)) {
      setState(() => _edge = color);
    }
  }

  /// The logo's corner colour when all four corners are opaque and alike.
  static Future<Color?> _edgeColor(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 16,
        targetHeight: 16,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final data = await frame.image.toByteData();
      frame.image.dispose();
      if (data == null) return null;
      const n = 16;
      final corners = [
        for (final (x, y) in const [
          (0, 0),
          (n - 1, 0),
          (0, n - 1),
          (n - 1, n - 1),
        ])
          (y * n + x) * 4,
      ];
      int channel(int i, int c) => data.getUint8(i + c);
      if (corners.any((i) => channel(i, 3) < 240)) return Colors.white;
      for (var c = 0; c < 3; c++) {
        final values = corners.map((i) => channel(i, c));
        if (values.reduce((a, b) => a > b ? a : b) -
                values.reduce((a, b) => a < b ? a : b) >
            24) {
          return Colors.white;
        }
      }
      final first = corners.first;
      return Color.fromARGB(
        255,
        channel(first, 0),
        channel(first, 1),
        channel(first, 2),
      );
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _edge ?? Colors.white,
      child: Padding(
        padding: EdgeInsets.all(widget.padding),
        child: Image.memory(
          widget.bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.placeholder,
        ),
      ),
    );
  }
}
