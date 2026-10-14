import 'dart:math' as math;
import 'dart:typed_data';

/// Web Mercator y (radians-based, unscaled) for a latitude in degrees.
double mercatorY(double latitude) {
  final phi = latitude.clamp(-85.0, 85.0) * math.pi / 180;
  return math.log(math.tan(math.pi / 4 + phi / 2));
}

double latitudeFromMercatorY(double y) => (2 * math.atan(math.exp(y)) - math.pi / 2) * 180 / math.pi;

/// A Web Mercator map rectangle, edges in degrees.
class GeoBounds {
  const GeoBounds({required this.north, required this.west, required this.south, required this.east});

  final double north;
  final double west;
  final double south;
  final double east;

  bool get isValid =>
      north > south &&
      east > west &&
      north <= 85 &&
      south >= -85 &&
      west >= -180 &&
      east <= 180 &&
      north - south >= 0.01 &&
      east - west >= 0.01;

  double get _top => mercatorY(north);
  double get _bottom => mercatorY(south);

  /// Position of a point as fractions of the map (0,0 top-left .. 1,1).
  (double x, double y) project(double latitude, double longitude) {
    final top = _top;
    return ((longitude - west) / (east - west), (top - mercatorY(latitude)) / (top - _bottom));
  }

  bool contains(double latitude, double longitude) =>
      latitude <= north && latitude >= south && longitude >= west && longitude <= east;

  bool overlaps(GeoBounds o) => o.west < east && o.east > west && o.south < north && o.north > south;

  GeoBounds union(GeoBounds o) => GeoBounds(
    north: math.max(north, o.north),
    west: math.min(west, o.west),
    south: math.min(south, o.south),
    east: math.max(east, o.east),
  );

  /// Same west/east/south edges, with the north edge placed so the map has
  /// the given pixel aspect ratio (height / width) in Web Mercator.
  GeoBounds withAspect(double heightOverWidth) {
    final spanX = (east - west) * math.pi / 180;
    return GeoBounds(
      north: latitudeFromMercatorY(_bottom + spanX * heightOverWidth),
      west: west,
      south: south,
      east: east,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeoBounds && other.north == north && other.west == west && other.south == south && other.east == east;

  @override
  int get hashCode => Object.hash(north, west, south, east);

  @override
  String toString() =>
      'GeoBounds(N ${north.toStringAsFixed(3)}, W ${west.toStringAsFixed(3)}, '
      'S ${south.toStringAsFixed(3)}, E ${east.toStringAsFixed(3)})';
}

/// Width and height from a PNG header, or null if [bytes] isn't a PNG.
(int width, int height)? pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}
