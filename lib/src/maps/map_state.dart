import 'dart:convert';
import 'dart:typed_data';

import '../engine/radio_event.dart';
import '../engine/radio_types.dart';
import 'geo.dart';

/// Which broadcast format a map came from: HERE Images (current iHeart
/// stations) or the older Total Traffic Network LOT files.
enum MapFormat { here, ttn }

/// One of the nine tiles of a traffic map.
class TrafficTile {
  const TrafficTile({required this.slot, required this.bytes, this.time, this.bounds});

  /// Row-major grid position 0..8.
  final int slot;
  final Uint8List bytes;
  final DateTime? time;

  /// Map edges of this tile (HERE only), when the broadcast values are sane.
  final GeoBounds? bounds;

  int get row => slot ~/ TrafficMap.columns;
  int get column => slot % TrafficMap.columns;
}

/// A 3×3 traffic map. Tiles arrive one at a time and are replaced
/// individually as the station refreshes them.
class TrafficMap {
  const TrafficMap({required this.format, required this.areaId, required this.tiles, this.frequencyHz});

  static const columns = 3;
  static const tileCount = 9;

  final MapFormat format;
  final String areaId;
  final Map<int, TrafficTile> tiles;

  /// Station the map was received from.
  final int? frequencyHz;

  bool get complete => tiles.length == tileCount;

  DateTime? get time {
    DateTime? newest;
    for (final t in tiles.values) {
      final time = t.time;
      if (time != null && (newest == null || time.isAfter(newest))) newest = time;
    }
    return newest;
  }
}

/// A radar image and the area it covers.
class WeatherFrame {
  const WeatherFrame({
    required this.format,
    required this.areaId,
    required this.bytes,
    this.time,
    this.bounds,
    this.frequencyHz,
  });

  final MapFormat format;
  final String areaId;
  final Uint8List bytes;
  final DateTime? time;

  /// Area covered; null when unknown (shown without a base map).
  final GeoBounds? bounds;
  final int? frequencyHz;
}

/// TTN radar overlay waiting for the DWRI_ file that says where it goes.
class _PendingOverlay {
  const _PendingOverlay(this.areaId, this.time, this.bytes, this.frequencyHz);
  final String areaId;
  final DateTime? time;
  final Uint8List bytes;
  final int? frequencyHz;
}

class MapsState {
  const MapsState({this.traffic, this.weather = const [], this.ttnWeatherArea}) : _pendingOverlay = null;

  const MapsState._(this.traffic, this.weather, this.ttnWeatherArea, this._pendingOverlay);

  static const maxWeatherFrames = 8;

  final TrafficMap? traffic;

  /// Radar frames for one area, oldest first.
  final List<WeatherFrame> weather;

  /// Area announced by the TTN weather service (DWRI_ file).
  final (String id, GeoBounds bounds)? ttnWeatherArea;
  final _PendingOverlay? _pendingOverlay;

  WeatherFrame? get latestWeather => weather.isEmpty ? null : weather.last;
  bool get isEmpty => traffic == null && weather.isEmpty;

  MapsState _copy({
    TrafficMap? traffic,
    List<WeatherFrame>? weather,
    (String, GeoBounds)? ttnWeatherArea,
    Object? pendingOverlay = _keep,
  }) => MapsState._(
    traffic ?? this.traffic,
    weather ?? this.weather,
    ttnWeatherArea ?? this.ttnWeatherArea,
    pendingOverlay == _keep ? _pendingOverlay : pendingOverlay as _PendingOverlay?,
  );
}

const _keep = Object();

/// `trafficMap_<row>_<column>_….png`, both digits 0–2, row 0 at the top.
final _hereTrafficName = RegExp(r'trafficMap_(\d)_(\d)(?:_|\.)');

(int row, int column)? hereTrafficPosition(String? name) {
  final m = _hereTrafficName.firstMatch(name ?? '');
  if (m == null) return null;
  final row = int.parse(m.group(1)!);
  final column = int.parse(m.group(2)!);
  if (row > 2 || column > 2) return null;
  return (row, column);
}

/// Places a complete grid by each tile's edges. HERE tiles are stored from
/// the filename instead, and the map view uses that.
Map<int, TrafficTile> arrangeTrafficTiles(TrafficMap map) {
  final tiles = map.tiles.values.toList();
  if (!map.complete || tiles.any((t) => t.bounds == null)) return map.tiles;
  final b0 = tiles.first.bounds!;
  List<double> bands(Iterable<double> values, double tolerance, {required bool descending}) {
    final sorted = values.toList()..sort();
    final out = <double>[];
    for (final v in sorted) {
      if (out.isEmpty || (v - out.last).abs() > tolerance) out.add(v);
    }
    return descending ? out.reversed.toList() : out;
  }

  int band(List<double> bands, double v) {
    var best = 0;
    for (var i = 1; i < bands.length; i++) {
      if ((bands[i] - v).abs() < (bands[best] - v).abs()) best = i;
    }
    return best;
  }

  final rows = bands(tiles.map((t) => t.bounds!.north), (b0.north - b0.south) * 0.3, descending: true);
  final columns = bands(tiles.map((t) => t.bounds!.west), (b0.east - b0.west) * 0.3, descending: false);
  if (rows.length != 3 || columns.length != 3) return map.tiles;
  final out = <int, TrafficTile>{
    for (final t in tiles) band(rows, t.bounds!.north) * TrafficMap.columns + band(columns, t.bounds!.west): t,
  };
  return out.length == TrafficMap.tileCount ? out : map.tiles;
}

/// Whether a LOT file belongs to the traffic/weather services.
bool isMapLot(HdLotEvent e) =>
    e.role == LotRole.traffic ||
    e.role == LotRole.weather ||
    e.name.startsWith('TMT_') ||
    e.name.startsWith('DWRO_') ||
    e.name.startsWith('DWRI_');

/// Folds traffic/weather map events into [s]. Pure; returns [s] unchanged
/// (identical) for anything it doesn't use.
MapsState reduceMaps(MapsState s, RadioEvent e, {int? frequencyHz}) {
  switch (e) {
    case HdHereImageEvent(imageType: HdHereImageEvent.traffic):
      if (e.data.isEmpty) return s;
      final named = hereTrafficPosition(e.name);
      final slot = named == null ? e.n1 - 1 : named.$1 * TrafficMap.columns + named.$2;
      if (slot < 0 || slot >= TrafficMap.tileCount) return s;
      final bounds = GeoBounds(north: e.north, west: e.west, south: e.south, east: e.east);
      return _addTile(
        s,
        MapFormat.here,
        _hereAreaId(e.name),
        TrafficTile(slot: slot, bytes: e.data, time: e.time, bounds: bounds.isValid ? bounds : null),
        frequencyHz,
      );
    case HdHereImageEvent(imageType: HdHereImageEvent.weather):
      if (e.data.isEmpty) return s;
      return _addFrame(
        s,
        WeatherFrame(
          format: MapFormat.here,
          areaId: _hereAreaId(e.name),
          bytes: e.data,
          time: e.time,
          bounds: _hereWeatherBounds(e),
          frequencyHz: frequencyHz,
        ),
      );
    case HdLotEvent() when isMapLot(e):
      return _reduceTtn(s, e, frequencyHz);
    default:
      return s;
  }
}

MapsState _addTile(MapsState s, MapFormat format, String areaId, TrafficTile tile, int? frequencyHz) {
  final previous = s.traffic;
  final sameMap = previous != null && previous.format == format && previous.areaId == areaId;
  final existing = sameMap ? previous.tiles[tile.slot] : null;
  if (existing != null && existing.time == tile.time && _sameBytes(existing.bytes, tile.bytes)) return s;
  return s._copy(
    traffic: TrafficMap(
      format: format,
      areaId: areaId,
      tiles: sameMap ? {...previous.tiles, tile.slot: tile} : {tile.slot: tile},
      frequencyHz: frequencyHz,
    ),
  );
}

MapsState _addFrame(MapsState s, WeatherFrame frame) {
  final sameArea = s.weather.isNotEmpty && s.weather.last.areaId == frame.areaId && s.weather.last.format == frame.format;
  if (sameArea && s.weather.any((f) => f.time == frame.time && _sameBytes(f.bytes, frame.bytes))) return s;
  final frames = [
    if (sameArea)
      for (final f in s.weather)
        if (frame.time == null || f.time != frame.time) f,
    frame,
  ]..sort((a, b) => (a.time ?? DateTime(0)).compareTo(b.time ?? DateTime(0)));
  while (frames.length > MapsState.maxWeatherFrames) {
    frames.removeAt(0);
  }
  return s._copy(weather: frames);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// HERE file names look like "trafficMap_1_2_rdhs.png" / "WeatherImage_0_0_rdhs.png";
/// the trailing part identifies the area.
String _hereAreaId(String? name) {
  if (name == null) return '';
  final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  final parts = base.split('_');
  return parts.length > 3 ? parts.sublist(3).join('_') : '';
}

/// HERE weather images carry their edges, but the north edge isn't always
/// right (nrsc5-dui rebuilds it from the traffic map). The images are Web
/// Mercator, so it follows from the image's aspect ratio.
GeoBounds? _hereWeatherBounds(HdHereImageEvent e) {
  final broadcast = GeoBounds(north: e.north, west: e.west, south: e.south, east: e.east);
  final size = pngSize(e.data);
  final sidesValid = e.east > e.west && e.west >= -180 && e.east <= 180 && e.south.abs() <= 85;
  if (size == null || size.$1 == 0 || !sidesValid) return broadcast.isValid ? broadcast : null;
  final fitted = broadcast.withAspect(size.$2 / size.$1);
  if (broadcast.isValid && (broadcast.north - fitted.north).abs() <= 0.03 * (fitted.north - fitted.south)) {
    return broadcast;
  }
  return fitted.isValid ? fitted : null;
}

// --- Total Traffic Network LOT files ----------------------------------------

final _tmtName = RegExp(r'^TMT_(.*)_([1-3])_([1-3])_(\d{8})_(\d{4})');
final _dwroName = RegExp(r'^DWRO_(.*)_.*_(\d{8})_(\d{4})');
final _dwriId = RegExp(r'DWR_Area_ID\s*=\s*"([^"]+)"');
final _dwriCoordinates = RegExp(
  r'Coordinates\s*=.*\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\).*\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)',
);

MapsState _reduceTtn(MapsState s, HdLotEvent e, int? frequencyHz) {
  final name = e.name;
  if (e.isImage) {
    final tmt = _tmtName.firstMatch(name);
    if (tmt != null) {
      final row = int.parse(tmt[2]!) - 1;
      final column = int.parse(tmt[3]!) - 1;
      return _addTile(
        s,
        MapFormat.ttn,
        tmt[1]!,
        TrafficTile(slot: row * TrafficMap.columns + column, bytes: e.data, time: _ttnTime(tmt[4]!, tmt[5]!)),
        frequencyHz,
      );
    }
    final dwro = _dwroName.firstMatch(name);
    if (dwro != null) {
      final overlay = _PendingOverlay(dwro[1]!, _ttnTime(dwro[2]!, dwro[3]!), e.data, frequencyHz);
      final area = s.ttnWeatherArea;
      if (area != null && area.$1 == overlay.areaId) return _addFrame(s, _ttnFrame(overlay, area.$2));
      return s._copy(pendingOverlay: overlay);
    }
    return s;
  }
  if (name.startsWith('DWRI_') && e.data.isNotEmpty) {
    final area = parseWeatherInfo(utf8.decode(e.data, allowMalformed: true));
    if (area == null) return s;
    if (s.ttnWeatherArea?.$1 == area.$1 && s.ttnWeatherArea?.$2 == area.$2 && s._pendingOverlay == null) return s;
    final pending = s._pendingOverlay;
    final next = s._copy(ttnWeatherArea: area, pendingOverlay: null);
    if (pending != null && pending.areaId == area.$1) return _addFrame(next, _ttnFrame(pending, area.$2));
    return next;
  }
  return s;
}

WeatherFrame _ttnFrame(_PendingOverlay o, GeoBounds bounds) => WeatherFrame(
  format: MapFormat.ttn,
  areaId: o.areaId,
  bytes: o.bytes,
  time: o.time,
  bounds: bounds,
  frequencyHz: o.frequencyHz,
);

DateTime? _ttnTime(String date, String time) {
  final y = int.parse(date.substring(0, 4));
  final mo = int.parse(date.substring(4, 6));
  final d = int.parse(date.substring(6, 8));
  final h = int.parse(time.substring(0, 2));
  final mi = int.parse(time.substring(2, 4));
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  return DateTime.utc(y, mo, d, h, mi);
}

/// Area id and edges from a TTN DWRI_ weather info file.
(String id, GeoBounds bounds)? parseWeatherInfo(String text) {
  final id = _dwriId.firstMatch(text)?[1];
  final c = _dwriCoordinates.firstMatch(text);
  if (id == null || c == null) return null;
  final lat1 = double.tryParse(c[1]!);
  final lon1 = double.tryParse(c[2]!);
  final lat2 = double.tryParse(c[3]!);
  final lon2 = double.tryParse(c[4]!);
  if (lat1 == null || lon1 == null || lat2 == null || lon2 == null) return null;
  final bounds = GeoBounds(
    north: lat1 > lat2 ? lat1 : lat2,
    west: lon1 < lon2 ? lon1 : lon2,
    south: lat1 > lat2 ? lat2 : lat1,
    east: lon1 < lon2 ? lon2 : lon1,
  );
  return bounds.isValid ? (id, bounds) : null;
}
