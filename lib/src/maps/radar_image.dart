import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

enum RadarKind {
  /// Has its own transparency: drawn over the base map as is.
  overlay,

  /// Opaque radar on black: black is keyed out before drawing.
  keyed,

  /// A complete opaque map: shown without a base map.
  opaque,
}

class PreparedRadar {
  const PreparedRadar(this.bytes, this.kind, this.width, this.height);

  /// Encoded image ready for [Image.memory].
  final Uint8List bytes;
  final RadarKind kind;
  final int width;
  final int height;

  bool get needsBaseMap => kind != RadarKind.opaque;
}

/// Classifies straight-alpha RGBA pixels.
RadarKind classifyRadarPixels(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  if (n == 0) return RadarKind.opaque;
  var translucent = 0;
  var dark = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] < 250) {
      translucent++;
    } else if (math.max(rgba[i], math.max(rgba[i + 1], rgba[i + 2])) < 24) {
      dark++;
    }
  }
  if (translucent > n * 0.02) return RadarKind.overlay;
  if (dark > n * 0.25) return RadarKind.keyed;
  return RadarKind.opaque;
}

/// Premultiplied RGBA with black made transparent (alpha follows the
/// brightest channel, so light rain stays faint and heavy cores solid).
Uint8List keyOutBlack(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final a = ((math.max(r, math.max(g, b)) - 16) * 2).clamp(0, 255);
    out[i] = r * a ~/ 255;
    out[i + 1] = g * a ~/ 255;
    out[i + 2] = b * a ~/ 255;
    out[i + 3] = a;
  }
  return out;
}

final _prepared = Expando<Future<PreparedRadar>>('radar');

/// Decodes and classifies a radar image once per byte buffer.
Future<PreparedRadar> prepareRadar(Uint8List encoded) => _prepared[encoded] ??= _prepare(encoded);

Future<PreparedRadar> _prepare(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  try {
    final w = image.width, h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return PreparedRadar(encoded, RadarKind.overlay, w, h);
    final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final kind = classifyRadarPixels(pixels);
    if (kind != RadarKind.keyed) return PreparedRadar(encoded, kind, w, h);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(keyOutBlack(pixels), w, h, ui.PixelFormat.rgba8888, completer.complete);
    final keyed = await completer.future;
    try {
      final png = await keyed.toByteData(format: ui.ImageByteFormat.png);
      return PreparedRadar(png == null ? encoded : png.buffer.asUint8List(), kind, w, h);
    } finally {
      keyed.dispose();
    }
  } finally {
    image.dispose();
  }
}
