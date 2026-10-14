import 'package:flutter/material.dart';

/// Five-bar strength indicator for a 0..1 quality value.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.quality, this.size = 20, this.color});

  final double quality;
  final double size;
  final Color? color;

  /// Maps HD MER (dB) or FM CNR (dB) onto 0..1.
  static double fromMer(double? merDb) => merDb == null ? 0 : ((merDb - 3) / 12).clamp(0, 1);
  static double fromCnr(double? cnrDb) => cnrDb == null ? 0 : ((cnrDb - 6) / 30).clamp(0, 1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = color ?? scheme.primary;
    final off = scheme.onSurface.withValues(alpha: 0.18);
    final lit = (quality * 5).ceil();
    return Semantics(
      label: 'Signal ${(quality * 100).round()} percent',
      child: SizedBox(
        width: size * 1.2,
        height: size,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 5; i++)
              Container(
                width: size * 0.16,
                height: size * (0.3 + 0.175 * i),
                decoration: BoxDecoration(
                  color: i < lit ? on : off,
                  borderRadius: BorderRadius.circular(size * 0.05),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
