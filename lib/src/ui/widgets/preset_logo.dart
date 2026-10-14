import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../settings/settings.dart';
import 'radio_select.dart';

/// A preset's station logo in a rounded square, or [placeholder] until one
/// has been received on this or an earlier visit.
class PresetLogo extends StatelessWidget {
  const PresetLogo({super.key, required this.preset, required this.size, required this.placeholder});

  final Preset preset;
  final double size;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return RadioSelect(
      select: (r) => r.stationLogo(preset.frequencyHz, preset.program),
      builder: (context, known) => _Loader(preset: preset, known: known, size: size, placeholder: placeholder),
    );
  }
}

class _Loader extends StatefulWidget {
  const _Loader({required this.preset, required this.known, required this.size, required this.placeholder});

  final Preset preset;
  final Uint8List? known;
  final double size;
  final Widget placeholder;

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  Uint8List? _loaded;
  String? _requested;

  String get _key => '${widget.preset.frequencyHz}/${widget.preset.program}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(_Loader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_requested != _key) _loaded = null;
    _maybeLoad();
  }

  void _maybeLoad() {
    if (widget.known != null) return;
    final key = _key;
    if (_requested == key) return;
    _requested = key;
    final preset = widget.preset;
    context.radio.loadStationLogo(preset.frequencyHz, preset.program).then((bytes) {
      if (!mounted || _requested != key || bytes == null) return;
      setState(() => _loaded = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.known ?? _loaded;
    final radius = BorderRadius.circular(widget.size / 5);
    return SizedBox.square(
      dimension: widget.size,
      child: bytes == null
          ? widget.placeholder
          : DecoratedBox(
              decoration: BoxDecoration(color: Colors.white, borderRadius: radius),
              child: ClipRRect(
                borderRadius: radius,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => widget.placeholder,
                ),
              ),
            ),
    );
  }
}
