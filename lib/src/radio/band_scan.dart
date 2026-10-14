import 'dart:math' as math;
import 'dart:typed_data';

import 'band_plan.dart';

/// Half of the usable spectrum around each capture center. The full capture
/// is ±744 kHz; the outer part is rolled off by the tuner's IF filter.
const scanHalfWidthHz = 500000;

/// Channel power is integrated over ±[_channelHalfWidthHz] (analog FM main
/// lobe), which stays clear of the HD sidebands at ±129..198 kHz.
const _channelHalfWidthHz = 60000;

/// Capture centers that tile [band] in [scanHalfWidthHz]*2 windows. Centers
/// sit half a channel step off-grid so the RTL-SDR DC spike never lands on a
/// channel.
List<int> scanCenters(BandPlan band) {
  final step = band.stepHz;
  var first = band.minHz + scanHalfWidthHz;
  first += step ~/ 2 - (first - band.minHz) % step;
  if (first - scanHalfWidthHz > band.minHz) first -= step;
  // The stride is a whole number of channel steps, so every center keeps the
  // half-step offset.
  final centers = <int>[];
  for (var c = first; c - scanHalfWidthHz <= band.maxHz; c += 2 * scanHalfWidthHz) {
    centers.add(c);
  }
  return centers;
}

class ChannelPower {
  const ChannelPower(this.frequencyHz, this.powerDb, this.snrDb);
  final int frequencyHz;
  final double powerDb;
  final double snrDb;
}

/// Measures every [band] channel inside one capture's usable window.
List<ChannelPower> measureChannels({
  required BandPlan band,
  required int centerHz,
  required int spanHz,
  required Float32List binsDb,
}) {
  final n = binsDb.length;
  if (n == 0) return const [];
  final binHz = spanHz / n;
  final usable = (scanHalfWidthHz / binHz).floor();
  final mid = n ~/ 2;
  final lo = math.max(0, mid - usable);
  final hi = math.min(n, mid + usable);
  final sorted = Float32List.fromList(binsDb.sublist(lo, hi))..sort();
  final floorDb = sorted[(sorted.length * 0.2).floor()];

  final out = <ChannelPower>[];
  for (final f in band.channels) {
    final offset = f - centerHz;
    if (offset < -scanHalfWidthHz || offset >= scanHalfWidthHz) continue;
    final first = ((offset - _channelHalfWidthHz) / binHz + n / 2).floor().clamp(0, n - 1);
    final last = ((offset + _channelHalfWidthHz) / binHz + n / 2).ceil().clamp(0, n - 1);
    var linear = 0.0;
    for (var b = first; b <= last; b++) {
      linear += math.pow(10, binsDb[b] / 10);
    }
    final meanDb = 10 * math.log(linear / (last - first + 1)) / math.ln10;
    out.add(ChannelPower(f, meanDb, meanDb - floorDb));
  }
  return out;
}

/// Picks channels that stand [minSnrDb] above the floor and are local maxima,
/// so a strong station's skirts don't register on its neighbors.
List<ChannelPower> pickStations(List<ChannelPower> channels, {double minSnrDb = 8}) {
  final sorted = [...channels]..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));
  final picked = <ChannelPower>[];
  for (var i = 0; i < sorted.length; i++) {
    final c = sorted[i];
    if (c.snrDb < minSnrDb) continue;
    final left = i > 0 ? sorted[i - 1].powerDb : double.negativeInfinity;
    final right = i + 1 < sorted.length ? sorted[i + 1].powerDb : double.negativeInfinity;
    if (c.powerDb >= left && c.powerDb >= right) picked.add(c);
  }
  return picked;
}
