import 'package:flutter/material.dart';

import '../../app.dart';
import '../../devices/device_service.dart';
import '../../engine/source_config.dart';

/// Bottom sheet listing USB tuners plus an rtl_tcp entry.
Future<void> showSourcePicker(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SourcePicker(),
    );

class _SourcePicker extends StatefulWidget {
  const _SourcePicker();

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  late Future<List<SdrDevice>> _devices;
  late final TextEditingController _host;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    final radio = AppScope.read(context).controller;
    _devices = radio.devices.listDevices();
    _host = TextEditingController(text: radio.settings.rtlTcpHost);
    _port = TextEditingController(text: '${radio.settings.rtlTcpPort}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radio = context.radio;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                Text('USB tuners', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() {
                    _devices = radio.devices.listDevices();
                  }),
                ),
              ],
            ),
            FutureBuilder(
              future: _devices,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  );
                }
                final list = snap.data ?? const [];
                if (snap.hasError || list.isEmpty) {
                  return ListTile(
                    leading: const Icon(Icons.usb_off),
                    title: const Text('No tuner found'),
                    subtitle: Text(
                      snap.hasError ? '${snap.error}' : 'Connect a tuner',
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final d in list)
                      ListTile(
                        leading: const Icon(Icons.usb),
                        title: Text(d.name),
                        subtitle: d.serial == null
                            ? null
                            : Text('S/N ${d.serial}'),
                        trailing: d.hasPermission
                            ? null
                            : const Icon(Icons.lock_outline),
                        onTap: () {
                          Navigator.pop(context);
                          radio.connectDevice(d);
                        },
                      ),
                  ],
                );
              },
            ),
            const Divider(height: 32),
            Text('rtl_tcp server', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _port,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.lan),
                label: const Text('Connect'),
                onPressed: () {
                  final host = _host.text.trim();
                  final port = int.tryParse(_port.text.trim()) ?? 1234;
                  if (host.isEmpty) return;
                  Navigator.pop(context);
                  radio
                    ..setRtlTcp(host, port)
                    ..connect(RtlTcpSource(host, port: port));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
