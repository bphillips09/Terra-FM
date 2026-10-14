import 'package:flutter/widgets.dart';

import '../../app.dart';
import '../../radio/radio_controller.dart';

/// Rebuilds only when [select] returns a different value (by `==`; state
/// sub-objects are replaced only when they change, so identity works).
/// The controller notifies ~30 times a second while streaming.
class RadioSelect<T> extends StatefulWidget {
  const RadioSelect({super.key, required this.select, required this.builder});

  final T Function(RadioController radio) select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<RadioSelect<T>> createState() => _RadioSelectState<T>();
}

class _RadioSelectState<T> extends State<RadioSelect<T>> {
  RadioController? _radio;
  late T _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final radio = context.radio;
    if (!identical(radio, _radio)) {
      _radio?.removeListener(_changed);
      _radio = radio..addListener(_changed);
      _value = widget.select(radio);
    }
  }

  @override
  void didUpdateWidget(RadioSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _value = widget.select(_radio!);
  }

  void _changed() {
    final next = widget.select(_radio!);
    if (next != _value) setState(() => _value = next);
  }

  @override
  void dispose() {
    _radio?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
