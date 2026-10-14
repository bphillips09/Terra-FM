import 'package:flutter/material.dart';

import '../../engine/radio_event.dart';

/// Live power spectrum of the whole capture, with the ±100 kHz channel and
/// the HD sidebands (±129..198 kHz) shaded.
class SpectrumView extends StatelessWidget {
  const SpectrumView({super.key, required this.spectrum, this.height = 180});

  final SpectrumEvent? spectrum;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SpectrumPainter(
          spectrum,
          line: scheme.primary,
          fill: scheme.primary.withValues(alpha: 0.15),
          grid: scheme.outlineVariant,
          channel: scheme.secondary.withValues(alpha: 0.12),
          sideband: scheme.tertiary.withValues(alpha: 0.14),
          text: scheme.onSurfaceVariant,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(
    this.spectrum, {
    required this.line,
    required this.fill,
    required this.grid,
    required this.channel,
    required this.sideband,
    required this.text,
  });

  final SpectrumEvent? spectrum;
  final Color line, fill, grid, channel, sideband, text;

  static const _topDb = 0.0;
  static const _bottomDb = -100.0;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (var db = _topDb; db >= _bottomDb; db -= 20) {
      final y = _y(db, size);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      _label(canvas, '${db.round()}', Offset(2, y + 1));
    }
    final s = spectrum;
    if (s == null || s.binsDb.isEmpty) return;

    double x(double offsetHz) => size.width * (0.5 + offsetHz / s.spanHz);
    canvas
      ..drawRect(Rect.fromLTRB(x(-100e3), 0, x(100e3), size.height), Paint()..color = channel)
      ..drawRect(Rect.fromLTRB(x(-198e3), 0, x(-129e3), size.height), Paint()..color = sideband)
      ..drawRect(Rect.fromLTRB(x(129e3), 0, x(198e3), size.height), Paint()..color = sideband);

    final n = s.binsDb.length;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final px = size.width * (i + 0.5) / n;
      final py = _y(s.binsDb[i].toDouble(), size);
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(area, Paint()..color = fill)
      ..drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

    final halfMhz = s.spanHz / 2e6;
    _label(canvas, '−${halfMhz.toStringAsFixed(2)} MHz', Offset(2, size.height - 14));
    _label(canvas, '+${halfMhz.toStringAsFixed(2)} MHz', Offset(size.width - 70, size.height - 14));
  }

  double _y(double db, Size size) =>
      size.height * (1 - ((db.clamp(_bottomDb, _topDb) - _bottomDb) / (_topDb - _bottomDb)));

  void _label(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: text, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => !identical(old.spectrum, spectrum) || old.line != line;
}
