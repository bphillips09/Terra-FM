import 'package:flutter/material.dart';

import '../../radio/radio_state.dart';
import 'radio_select.dart';
import 'source_picker.dart';

/// Covers Listen, Stations, and Maps until a tuner is streaming. Settings
/// stays reachable from the navigation.
class TunerGate extends StatelessWidget {
  const TunerGate({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RadioSelect(
      select: (r) => (
        r.state.phase,
        r.state.errorMessage,
        r.state.sourceLabel,
        r.reconnecting,
      ),
      builder: (context, v) {
        final (phase, error, label, reconnecting) = v;
        final waiting = reconnecting && phase != ConnectionPhase.connecting;
        final connecting = phase == ConnectionPhase.connecting || waiting;
        final (icon, text) = switch (phase) {
          ConnectionPhase.connecting => (
            Icons.sync,
            'Connecting to ${label ?? 'tuner'}…',
          ),
          _ when waiting => (
            Icons.usb_off,
            '${error ?? 'Tuner disconnected'}. Reconnecting when it is back…',
          ),
          ConnectionPhase.lost => (
            Icons.usb_off,
            error ?? 'Tuner disconnected',
          ),
          ConnectionPhase.error => (
            Icons.error_outline,
            error ?? 'Could not open the tuner',
          ),
          ConnectionPhase.ended => (
            Icons.stop_circle_outlined,
            'Recording finished',
          ),
          _ => (Icons.settings_input_antenna, 'Connect a tuner'),
        };
        return Stack(
          children: [
            ModalBarrier(
              dismissible: false,
              color: scheme.scrim.withValues(alpha: 0.45),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (connecting)
                          const SizedBox.square(
                            dimension: 36,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        else
                          Icon(icon, size: 40, color: scheme.primary),
                        const SizedBox(height: 16),
                        Text(
                          text,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (!connecting) ...[
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: () => showSourcePicker(context),
                            child: const Text('Source'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
