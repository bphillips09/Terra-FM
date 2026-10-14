/// FM broadcast band definitions. HD (NRSC-5) is only on air in the
/// Americas, but analog FM works anywhere.
enum BandPlan {
  northAmerica('North America', 87900000, 107900000, 200000, 75),
  americas('Americas (100 kHz)', 87500000, 108000000, 100000, 75),
  europe('Europe / World', 87500000, 108000000, 100000, 50),
  japan('Japan', 76000000, 95000000, 100000, 50);

  const BandPlan(this.label, this.minHz, this.maxHz, this.stepHz, this.deemphasisUs);

  final String label;
  final int minHz;
  final int maxHz;
  final int stepHz;
  final int deemphasisUs;

  static BandPlan fromName(String? name) => values.firstWhere((b) => b.name == name, orElse: () => northAmerica);

  int get channelCount => (maxHz - minHz) ~/ stepHz + 1;

  Iterable<int> get channels sync* {
    for (var f = minHz; f <= maxHz; f += stepHz) {
      yield f;
    }
  }

  /// Nearest channel to [hz] inside the band.
  int snap(int hz) {
    final clamped = hz.clamp(minHz, maxHz);
    final steps = ((clamped - minHz) / stepHz).round();
    return minHz + steps * stepHz;
  }

  /// [steps] channels away from [hz], wrapping around the band edges.
  int step(int hz, int steps) {
    final n = channelCount;
    final index = ((snap(hz) - minHz) ~/ stepHz + steps) % n;
    return minHz + (index < 0 ? index + n : index) * stepHz;
  }

  bool contains(int hz) => hz >= minHz && hz <= maxHz;
}

String formatMhz(int hz, {int decimals = 1}) => (hz / 1e6).toStringAsFixed(decimals);
