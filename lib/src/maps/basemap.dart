import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'geo.dart';

/// Layer ids in assets/maps/north_america.tbm (see tool/build_basemap.dart).
enum BaseMapLayer {
  land(1),
  lakes(2),
  countryBorders(3),
  stateBorders(4),
  majorRoads(5),
  roads(6),
  cities(7);

  const BaseMapLayer(this.id);
  final int id;
}

/// A polyline or polygon ring, longitude/latitude interleaved.
class GeoLine {
  GeoLine(this.points) {
    for (var i = 0; i < points.length; i += 2) {
      minLon = math.min(minLon, points[i]);
      maxLon = math.max(maxLon, points[i]);
      minLat = math.min(minLat, points[i + 1]);
      maxLat = math.max(maxLat, points[i + 1]);
    }
  }

  final Float32List points;
  double minLon = double.infinity, maxLon = -double.infinity;
  double minLat = double.infinity, maxLat = -double.infinity;

  bool overlaps(GeoBounds b) => minLon <= b.east && maxLon >= b.west && minLat <= b.north && maxLat >= b.south;
}

class City {
  const City(this.name, this.latitude, this.longitude, this.population);
  final String name;
  final double latitude;
  final double longitude;
  final int population;
}

/// Offline Natural Earth base map for North America.
class BaseMap {
  BaseMap._(this.layers, this.cities);

  static const asset = 'assets/maps/north_america.tbm';
  static Future<BaseMap>? _loading;

  final Map<BaseMapLayer, List<GeoLine>> layers;

  /// Largest first.
  final List<City> cities;

  static Future<BaseMap> load([AssetBundle? bundle]) => _loading ??= (bundle ?? rootBundle)
      .load(asset)
      .then((d) => BaseMap.decode(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)));

  factory BaseMap.decode(Uint8List bytes) {
    final r = _Reader(bytes);
    if (ascii.decode(r.take(4)) != 'TBM1') throw const FormatException('Not a Terra base map');
    r.byte(); // version
    final layerCount = r.byte();
    final layers = <BaseMapLayer, List<GeoLine>>{};
    final cities = <City>[];
    for (var l = 0; l < layerCount; l++) {
      final id = r.byte();
      final kind = r.byte();
      final count = r.varint();
      final layer = BaseMapLayer.values.where((b) => b.id == id).firstOrNull;
      if (kind == 0) {
        final lines = <GeoLine>[];
        for (var f = 0; f < count; f++) {
          final n = r.varint();
          final pts = Float32List(n * 2);
          var x = 0, y = 0;
          for (var i = 0; i < n; i++) {
            x += r.zigzag();
            y += r.zigzag();
            pts[i * 2] = x / 1000;
            pts[i * 2 + 1] = y / 1000;
          }
          lines.add(GeoLine(pts));
        }
        if (layer != null) layers[layer] = lines;
      } else {
        for (var c = 0; c < count; c++) {
          final lon = r.zigzag() / 1000;
          final lat = r.zigzag() / 1000;
          final pop = r.varint() * 1000;
          final name = utf8.decode(r.take(r.byte()), allowMalformed: true);
          cities.add(City(name, lat, lon, pop));
        }
      }
    }
    return BaseMap._(layers, cities);
  }
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  int byte() => bytes[offset++];

  Uint8List take(int n) => Uint8List.sublistView(bytes, offset, offset += n);

  int varint() {
    var result = 0, shift = 0;
    while (true) {
      final b = byte();
      result |= (b & 0x7F) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  int zigzag() {
    final v = varint();
    return (v & 1) == 0 ? v >> 1 : -((v + 1) >> 1);
  }
}

class BaseMapColors {
  const BaseMapColors({
    required this.water,
    required this.land,
    required this.border,
    required this.road,
    required this.majorRoad,
    required this.label,
    required this.labelHalo,
    required this.marker,
  });

  factory BaseMapColors.forBrightness(Brightness brightness, Color accent) => brightness == Brightness.dark
      ? BaseMapColors(
          water: const Color(0xFF0D1B26),
          land: const Color(0xFF20262B),
          border: const Color(0xFF65707C),
          road: const Color(0xFF4A4436),
          majorRoad: const Color(0xFF7A6640),
          label: const Color(0xFFD5DADF),
          labelHalo: const Color(0xCC0D1114),
          marker: accent,
        )
      : BaseMapColors(
          water: const Color(0xFFB4CFE3),
          land: const Color(0xFFF1EFE9),
          border: const Color(0xFF8D939A),
          road: const Color(0xFFE2C890),
          majorRoad: const Color(0xFFCC9A48),
          label: const Color(0xFF2C3136),
          labelHalo: const Color(0xCCFFFFFF),
          marker: accent,
        );

  final Color water;
  final Color land;
  final Color border;
  final Color road;
  final Color majorRoad;
  final Color label;
  final Color labelHalo;
  final Color marker;

  @override
  bool operator ==(Object other) =>
      other is BaseMapColors &&
      other.water == water &&
      other.land == land &&
      other.border == border &&
      other.road == road &&
      other.majorRoad == majorRoad &&
      other.label == label &&
      other.labelHalo == labelHalo &&
      other.marker == marker;

  @override
  int get hashCode => Object.hash(water, land, border, road, majorRoad, label, labelHalo, marker);
}

/// Draws [map] for [bounds] (Web Mercator), with an optional marker.
class BaseMapPainter extends CustomPainter {
  BaseMapPainter({
    required this.map,
    required this.bounds,
    required this.colors,
    this.marker,
    this.labelStyle = const TextStyle(),
  });

  final BaseMap map;
  final GeoBounds bounds;
  final BaseMapColors colors;
  final (double latitude, double longitude)? marker;

  /// Font for city names; size, colour and weight are set by the painter.
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final top = mercatorY(bounds.north);
    final sx = size.width / (bounds.east - bounds.west);
    final sy = size.height / (top - mercatorY(bounds.south));
    Offset project(double lon, double lat) => Offset((lon - bounds.west) * sx, (top - mercatorY(lat)) * sy);

    // A margin so lines leaving the frame aren't culled early.
    final padLon = (bounds.east - bounds.west) * 0.1;
    final padLat = (bounds.north - bounds.south) * 0.1;
    final view = GeoBounds(
      north: bounds.north + padLat,
      west: bounds.west - padLon,
      south: bounds.south - padLat,
      east: bounds.east + padLon,
    );

    Path pathFor(BaseMapLayer layer, {bool close = false}) {
      final path = Path()..fillType = PathFillType.evenOdd;
      for (final line in map.layers[layer] ?? const <GeoLine>[]) {
        if (!line.overlaps(view)) continue;
        final p = line.points;
        path.addPolygon([for (var i = 0; i < p.length; i += 2) project(p[i], p[i + 1])], close);
      }
      return path;
    }

    canvas
      ..clipRect(Offset.zero & size)
      ..drawColor(colors.water, BlendMode.src)
      ..drawPath(pathFor(BaseMapLayer.land, close: true), Paint()..color = colors.land)
      ..drawPath(pathFor(BaseMapLayer.lakes, close: true), Paint()..color = colors.water);

    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    canvas
      ..drawPath(pathFor(BaseMapLayer.roads), stroke(colors.road, 0.8))
      ..drawPath(pathFor(BaseMapLayer.majorRoads), stroke(colors.majorRoad, 1.5))
      ..drawPath(pathFor(BaseMapLayer.stateBorders), stroke(colors.border, 0.9))
      ..drawPath(pathFor(BaseMapLayer.countryBorders), stroke(colors.border, 1.6));

    _paintCities(canvas, size, project);

    final m = marker;
    if (m != null && bounds.contains(m.$1, m.$2)) {
      final c = project(m.$2, m.$1);
      canvas
        ..drawCircle(c, 7, Paint()..color = colors.labelHalo)
        ..drawCircle(c, 5, Paint()..color = colors.marker)
        ..drawCircle(c, 2, Paint()..color = colors.labelHalo);
    }
  }

  void _paintCities(Canvas canvas, Size size, Offset Function(double lon, double lat) project) {
    final span = bounds.east - bounds.west;
    final minPopulation = span > 8
        ? 250000
        : span > 4
        ? 80000
        : 15000;
    final placed = <Rect>[];
    final dot = Paint()..color = colors.label;
    final fontSize = (size.shortestSide / 40).clamp(9.0, 14.0);
    for (final city in map.cities) {
      if (placed.length >= 24 || city.population < minPopulation) break;
      if (!bounds.contains(city.latitude, city.longitude)) continue;
      final at = project(city.longitude, city.latitude);
      final text = TextPainter(
        text: TextSpan(
          text: city.name,
          style: labelStyle.copyWith(
            fontSize: fontSize,
            color: colors.label,
            fontWeight: city.population >= 500000 ? FontWeight.w600 : FontWeight.w400,
            shadows: [Shadow(color: colors.labelHalo, blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final rect = Rect.fromLTWH(at.dx + 4, at.dy - text.height / 2, text.width, text.height);
      if (rect.right > size.width || rect.top < 0 || rect.bottom > size.height) {
        text.dispose();
        continue;
      }
      if (placed.any((r) => r.inflate(3).overlaps(rect))) {
        text.dispose();
        continue;
      }
      placed.add(rect.expandToInclude(Rect.fromCircle(center: at, radius: 2)));
      canvas.drawCircle(at, 2, dot);
      text
        ..paint(canvas, rect.topLeft)
        ..dispose();
    }
  }

  @override
  bool shouldRepaint(BaseMapPainter old) =>
      old.map != map ||
      old.bounds != bounds ||
      old.colors != colors ||
      old.marker != marker ||
      old.labelStyle != labelStyle;
}
