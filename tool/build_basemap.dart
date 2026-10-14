// Builds the offline base map drawn under weather radar images
// (assets/maps/north_america.tbm) from Natural Earth (public domain).
//
//   fvm dart run tool/build_basemap.dart
//
// Downloads are cached in build/basemap_src/. The output format is decoded by
// lib/src/maps/basemap.dart:
//
//   "TBM1" u8 version, u8 layerCount, then per layer:
//     u8 layerId, u8 kind (0 = polylines/rings, 1 = labelled points), varint count
//     kind 0: per feature varint pointCount, then zigzag varint (dLon, dLat)
//             steps of 1/1000 degree from the previous point (first from 0).
//     kind 1: zigzag varint lon, lat (1/1000 degree), varint population / 1000,
//             u8 name length, UTF-8 name.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _release = 'v5.1.2';
const _baseUrl = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$_release/geojson';

// Region covered: the US (with Alaska, Hawaii, Puerto Rico), southern Canada
// and Mexico.
const _west = -170.0;
const _east = -50.0;
const _south = 13.0;
const _north = 63.0;

/// Simplification tolerance in degrees (well under a pixel at metro zoom).
const _tolerance = 0.004;
const _quantum = 1000; // steps per degree

// Layer ids; keep in sync with BaseMapLayer in lib/src/maps/basemap.dart.
const _land = 1;
const _lakes = 2;
const _countryBorders = 3;
const _stateBorders = 4;
const _majorRoads = 5;
const _roads = 6;
const _cities = 7;

typedef Pt = (double lon, double lat);

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final cache = Directory('${root.path}/build/basemap_src')..createSync(recursive: true);

  Future<List<Map<String, Object?>>> features(String name) async {
    final file = File('${cache.path}/$name.geojson');
    if (!file.existsSync()) {
      stdout.writeln('Downloading $name ...');
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse('$_baseUrl/$name.geojson'))).close();
        if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode} for $name');
        await response.pipe(file.openWrite());
      } finally {
        client.close();
      }
    }
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return [for (final f in json['features']! as List<Object?>) (f! as Map).cast<String, Object?>()];
  }

  final layers = <(int, List<List<Pt>>)>[];

  stdout.writeln('Land');
  layers.add((_land, _rings(await features('ne_10m_admin_0_countries_lakes'), minSpan: 0.02)));

  stdout.writeln('Lakes');
  layers.add((_lakes, _rings(await features('ne_10m_lakes'), minSpan: 0.03)));

  stdout.writeln('Borders');
  layers.add((_countryBorders, _lines(await features('ne_10m_admin_0_boundary_lines_land'))));
  layers.add((
    _stateBorders,
    _lines(await features('ne_10m_admin_1_states_provinces_lines'), where: (p) => const {'USA', 'CAN', 'MEX'}.contains(p['ADM0_A3'])),
  ));

  stdout.writeln('Roads');
  final roads = [for (final f in await features('ne_10m_roads')) if (_props(f)['continent'] == 'North America') f];
  bool isMajor(Map<String, Object?> p) => p['expressway'] == 1 || p['level'] == 'Interstate';
  layers.add((_majorRoads, _lines(roads, where: isMajor)));
  layers.add((
    _roads,
    _lines(
      roads,
      where: (p) => !isMajor(p) && p['level'] == 'Federal' && const {'Major Highway', 'Secondary Highway'}.contains(p['type']),
    ),
  ));

  stdout.writeln('Cities');
  final cities = <(Pt, int, String)>[];
  for (final f in await features('ne_10m_populated_places_simple')) {
    final p = _props(f);
    final lon = (p['longitude']! as num).toDouble();
    final lat = (p['latitude']! as num).toDouble();
    final pop = (p['pop_max'] as num?)?.toInt() ?? 0;
    if (!_inRegion((lon, lat)) || pop < 15000) continue;
    cities.add(((lon, lat), pop, (p['nameascii'] ?? p['name'])! as String));
  }
  cities.sort((a, b) => b.$2.compareTo(a.$2));

  final out = BytesBuilder();
  out
    ..add(ascii.encode('TBM1'))
    ..addByte(1)
    ..addByte(layers.length + 1);
  for (final (id, features) in layers) {
    out
      ..addByte(id)
      ..addByte(0);
    _varint(out, features.length);
    var points = 0;
    for (final line in features) {
      _varint(out, line.length);
      var px = 0;
      var py = 0;
      for (final (lon, lat) in line) {
        final x = (lon * _quantum).round();
        final y = (lat * _quantum).round();
        _zigzag(out, x - px);
        _zigzag(out, y - py);
        px = x;
        py = y;
      }
      points += line.length;
    }
    stdout.writeln('  layer $id: ${features.length} features, $points points');
  }
  out
    ..addByte(_cities)
    ..addByte(1);
  _varint(out, cities.length);
  for (final ((lon, lat), pop, name) in cities) {
    _zigzag(out, (lon * _quantum).round());
    _zigzag(out, (lat * _quantum).round());
    _varint(out, pop ~/ 1000);
    final bytes = utf8.encode(name);
    out
      ..addByte(math.min(bytes.length, 255))
      ..add(bytes.take(255).toList());
  }
  stdout.writeln('  cities: ${cities.length}');

  final target = File('${root.path}/assets/maps/north_america.tbm')..createSync(recursive: true);
  target.writeAsBytesSync(out.takeBytes());
  stdout.writeln('Wrote ${target.path} (${(target.lengthSync() / 1024).toStringAsFixed(0)} KB)');
}

Map<String, Object?> _props(Map<String, Object?> f) => (f['properties']! as Map).cast<String, Object?>();

bool _inRegion(Pt p) => p.$1 >= _west && p.$1 <= _east && p.$2 >= _south && p.$2 <= _north;

/// Outer and inner rings of (multi)polygons, clipped to the region.
List<List<Pt>> _rings(List<Map<String, Object?>> features, {required double minSpan}) {
  final out = <List<Pt>>[];
  for (final f in features) {
    final geometry = f['geometry'] as Map<String, Object?>?;
    if (geometry == null) continue;
    final coords = geometry['coordinates']! as List<Object?>;
    final polygons = geometry['type'] == 'Polygon' ? [coords] : coords;
    for (final polygon in polygons) {
      for (final ring in polygon! as List<Object?>) {
        final clipped = _clipRing(_points(ring! as List<Object?>));
        if (clipped.length < 4 || _span(clipped) < minSpan) continue;
        final simple = _simplify(clipped);
        if (simple.length >= 4) out.add(simple);
      }
    }
  }
  return out;
}

/// (Multi)line strings, cut to the parts inside the region.
List<List<Pt>> _lines(List<Map<String, Object?>> features, {bool Function(Map<String, Object?>)? where}) {
  final out = <List<Pt>>[];
  for (final f in features) {
    if (where != null && !where(_props(f))) continue;
    final geometry = f['geometry'] as Map<String, Object?>?;
    if (geometry == null) continue;
    final coords = geometry['coordinates']! as List<Object?>;
    final parts = geometry['type'] == 'LineString' ? [coords] : coords;
    for (final part in parts) {
      for (final run in _clipLine(_points(part! as List<Object?>))) {
        final simple = _simplify(run);
        if (simple.length >= 2) out.add(simple);
      }
    }
  }
  return out;
}

List<Pt> _points(List<Object?> coords) => [
  for (final c in coords) ((((c! as List)[0]) as num).toDouble(), ((c as List)[1] as num).toDouble()),
];

double _span(List<Pt> pts) {
  var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
  for (final (x, y) in pts) {
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return math.max(maxX - minX, maxY - minY);
}

/// Sutherland–Hodgman against the region rectangle.
List<Pt> _clipRing(List<Pt> ring) {
  var pts = ring;
  for (final edge in const [0, 1, 2, 3]) {
    if (pts.isEmpty) break;
    bool inside(Pt p) => switch (edge) {
      0 => p.$1 >= _west,
      1 => p.$1 <= _east,
      2 => p.$2 >= _south,
      _ => p.$2 <= _north,
    };
    Pt cross(Pt a, Pt b) {
      final (ax, ay) = a;
      final (bx, by) = b;
      if (edge < 2) {
        final x = edge == 0 ? _west : _east;
        return (x, ay + (by - ay) * (x - ax) / (bx - ax));
      }
      final y = edge == 2 ? _south : _north;
      return (ax + (bx - ax) * (y - ay) / (by - ay), y);
    }

    final next = <Pt>[];
    for (var i = 0; i < pts.length; i++) {
      final cur = pts[i];
      final prev = pts[(i + pts.length - 1) % pts.length];
      if (inside(cur)) {
        if (!inside(prev)) next.add(cross(prev, cur));
        next.add(cur);
      } else if (inside(prev)) {
        next.add(cross(prev, cur));
      }
    }
    pts = next;
  }
  if (pts.isNotEmpty && pts.first != pts.last) pts = [...pts, pts.first];
  return pts;
}

/// Runs of consecutive points touching the region (one point of slack on
/// each side so lines reach the edge).
List<List<Pt>> _clipLine(List<Pt> line) {
  final runs = <List<Pt>>[];
  var run = <Pt>[];
  for (var i = 0; i < line.length; i++) {
    final near = _inRegion(line[i]) || (i > 0 && _inRegion(line[i - 1])) || (i + 1 < line.length && _inRegion(line[i + 1]));
    if (near) {
      run.add(line[i]);
    } else if (run.isNotEmpty) {
      if (run.length >= 2) runs.add(run);
      run = <Pt>[];
    }
  }
  if (run.length >= 2) runs.add(run);
  return runs;
}

/// Douglas–Peucker (iterative), longitude scaled by cos(latitude).
List<Pt> _simplify(List<Pt> pts) {
  if (pts.length <= 2) return pts;
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    final k = math.cos((pts[a].$2 + pts[b].$2) / 2 * math.pi / 180);
    final ax = pts[a].$1 * k, ay = pts[a].$2;
    final bx = pts[b].$1 * k, by = pts[b].$2;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var best = -1;
    var bestDist = _tolerance * _tolerance;
    for (var i = a + 1; i < b; i++) {
      final px = pts[i].$1 * k - ax, py = pts[i].$2 - ay;
      double d2;
      if (len2 == 0) {
        d2 = px * px + py * py;
      } else {
        final t = ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
        final ex = px - t * dx, ey = py - t * dy;
        d2 = ex * ex + ey * ey;
      }
      if (d2 > bestDist) {
        bestDist = d2;
        best = i;
      }
    }
    if (best > 0) {
      keep[best] = true;
      stack
        ..add((a, best))
        ..add((best, b));
    }
  }
  return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
}

void _varint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
}

void _zigzag(BytesBuilder out, int value) => _varint(out, value >= 0 ? value << 1 : ((-value) << 1) - 1);
