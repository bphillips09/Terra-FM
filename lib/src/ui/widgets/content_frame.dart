import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Centers [child] in a column of at most [maxWidth]. Wide windows keep
/// labels next to their controls instead of stretching a row across the
/// screen; narrow ones are unchanged.
class ContentFrame extends StatelessWidget {
  const ContentFrame({super.key, this.maxWidth = 840, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: math.min(maxWidth, c.maxWidth), height: c.maxHeight, child: child),
      ),
    );
  }
}
