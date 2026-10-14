import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Scales everything below it, like changing the display density: layout
/// sees a screen of `size / scale` logical pixels, then the result is drawn
/// `scale` times larger. Dialogs and menus are included when this wraps the
/// navigator (MaterialApp.builder).
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.scale, required this.child});

  /// Null picks [automatic] for the current screen.
  final double? scale;
  final Widget child;

  static const minScale = 0.75;
  static const maxScale = 1.5;

  /// Larger on low-density landscape screens (car head units commonly run
  /// 1024×600 or 1280×720 at 1.0–1.33×), smaller on very small ones.
  /// Desktop windows are left alone.
  static double automatic(Size size, double devicePixelRatio, TargetPlatform platform) {
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) return 1;
    final shortest = size.shortestSide;
    double scale = 1;
    if (shortest < 360) {
      scale = math.max(minScale, shortest / 360);
    } else if (devicePixelRatio <= 1.34 && shortest > 520) {
      scale = math.min(maxScale, shortest / 480);
    }
    return (scale * 20).round() / 20;
  }

  /// The scale in effect and the automatic choice for this screen.
  static UiScaleInfo of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UiScaleScope>()?.info ?? const UiScaleInfo(1, 1);

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final auto = automatic(mq.size, mq.devicePixelRatio, defaultTargetPlatform);
    final s = (scale ?? auto).clamp(minScale, maxScale);
    return _UiScaleScope(
      info: UiScaleInfo(s, auto),
      child: _ScaledBox(
        scale: s,
        child: MediaQuery(
          data: mq.copyWith(
            size: mq.size / s,
            devicePixelRatio: mq.devicePixelRatio * s,
            padding: mq.padding / s,
            viewPadding: mq.viewPadding / s,
            viewInsets: mq.viewInsets / s,
            systemGestureInsets: mq.systemGestureInsets / s,
          ),
          child: child,
        ),
      ),
    );
  }
}

@immutable
class UiScaleInfo {
  const UiScaleInfo(this.scale, this.automatic);
  final double scale;
  final double automatic;

  @override
  bool operator ==(Object other) => other is UiScaleInfo && other.scale == scale && other.automatic == automatic;

  @override
  int get hashCode => Object.hash(scale, automatic);
}

class _UiScaleScope extends InheritedWidget {
  const _UiScaleScope({required this.info, required super.child});
  final UiScaleInfo info;

  @override
  bool updateShouldNotify(_UiScaleScope oldWidget) => info != oldWidget.info;
}

/// Lays [child] out at `available / scale` and paints it scaled to fill.
/// The widget structure is the same at every scale, so state survives
/// rotation and resizing.
class _ScaledBox extends StatelessWidget {
  const _ScaledBox({required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return child;
        final size = constraints.biggest;
        return SizedBox.fromSize(
          size: size,
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(width: size.width / scale, height: size.height / scale, child: child),
          ),
        );
      },
    );
  }
}

/// Gives [child] the full width and its natural height, scaled down if that
/// is taller than the space available.
class ShrinkToFit extends StatelessWidget {
  const ShrinkToFit({super.key, this.alignment = Alignment.centerLeft, required this.child});
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: SizedBox(width: c.maxWidth, child: child),
      ),
    );
  }
}
