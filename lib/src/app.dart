import 'package:flutter/material.dart';

import 'logging/log_buffer.dart';
import 'radio/radio_controller.dart';
import 'settings/settings.dart';
import 'ui/maps_page.dart';
import 'ui/now_playing_page.dart';
import 'ui/settings_page.dart';
import 'ui/stations_page.dart';
import 'ui/widgets/radio_select.dart';
import 'ui/widgets/tuner_gate.dart';
import 'ui/widgets/ui_scale.dart';

/// Makes the controller and log buffer available to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.controller,
    required this.logs,
    required super.child,
  });

  final RadioController controller;
  final LogBuffer logs;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// Like [of] without registering a dependency, so it is safe in `initState`.
  static AppScope read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      controller != oldWidget.controller || logs != oldWidget.logs;
}

extension AppScopeContext on BuildContext {
  RadioController get radio => AppScope.of(this).controller;
}

class TerraApp extends StatelessWidget {
  const TerraApp({super.key, required this.controller, required this.logs});

  final RadioController controller;
  final LogBuffer logs;

  static const _seed = Color(0xFF00796B);

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      logs: logs,
      child: RadioSelect(
        select: (r) => (r.settings.uiScale, r.settings.theme),
        builder: (context, v) {
          final (scale, theme) = v;
          return MaterialApp(
            title: 'Terra FM',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: _seed),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: _seed,
                brightness: Brightness.dark,
              ),
            ),
            themeMode: switch (theme) {
              AppTheme.system => ThemeMode.system,
              AppTheme.light => ThemeMode.light,
              AppTheme.dark => ThemeMode.dark,
            },
            builder: (context, child) => UiScale(scale: scale, child: child!),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  MapKind _mapKind = MapKind.traffic;

  /// Keeps page state when rotating swaps the rail for the bottom bar.
  final _bodyKey = GlobalKey();

  static const _listen = 0, _stations = 1, _maps = 2, _settings = 3;

  static const _destinations = [
    (icon: Icons.radio_outlined, selected: Icons.radio, label: 'Listen'),
    (
      icon: Icons.list_alt_outlined,
      selected: Icons.list_alt,
      label: 'Stations',
    ),
    (icon: Icons.map_outlined, selected: Icons.map, label: 'Maps'),
    (
      icon: Icons.settings_outlined,
      selected: Icons.settings,
      label: 'Settings',
    ),
  ];

  Widget _page(int index) => switch (index) {
    _listen => const NowPlayingPage(),
    _stations => StationsPage(onTuned: () => setState(() => _index = _listen)),
    _maps => MapsPage(
      kind: _mapKind,
      onKindChanged: (k) => setState(() => _mapKind = k),
    ),
    _ => const SettingsPage(),
  };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Landscape head units are short: a side rail keeps the full height for
    // content.
    final rail =
        size.width >= 720 || (size.width > size.height && size.width >= 480);
    return RadioSelect(
      select: (r) => r.state.isStreaming,
      builder: (context, streaming) {
        final page = KeyedSubtree(key: _bodyKey, child: _page(_index));
        final body = Stack(
          children: [
            page,
            if (!streaming && _index != _settings)
              const Positioned.fill(child: TunerGate()),
          ],
        );
        return _scaffold(size, rail, body);
      },
    );
  }

  Widget _scaffold(Size size, bool rail, Widget body) {
    if (rail) {
      return Scaffold(
        body: Row(
          children: [
            // Scrolls instead of overflowing when a window is shorter than
            // the destinations.
            LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: switch (size.height) {
                        < 360 => NavigationRailLabelType.none,
                        < 440 => NavigationRailLabelType.selected,
                        _ => NavigationRailLabelType.all,
                      },
                      groupAlignment: 0,
                      destinations: [
                        for (final d in _destinations)
                          NavigationRailDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.selected),
                            label: Text(d.label),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
