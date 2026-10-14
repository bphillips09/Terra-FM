import 'dart:io';
import 'dart:typed_data';

/// Persists HD station logos so they show immediately on the next tune, and
/// writes the current artwork to a file for the media notification (which
/// needs a URI, not bytes).
class ArtCache {
  ArtCache(this._directory);

  final Directory? _directory;
  final _memory = <String, Uint8List>{};

  /// Keyed by frequency (known immediately on tune, unlike the station's
  /// facility id, which arrives with SIS a second or so later).
  static String logoKey({required int frequencyHz, required int program}) => 'logo_${frequencyHz}_$program';

  Uint8List? memory(String key) => _memory[key];

  Future<Uint8List?> load(String key) async {
    final cached = _memory[key];
    if (cached != null) return cached;
    final dir = _directory;
    if (dir == null) return null;
    final file = File('${dir.path}/$key.img');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    _memory[key] = bytes;
    return bytes;
  }

  Future<void> store(String key, Uint8List bytes) async {
    final previous = _memory[key];
    if (previous != null && _sameBytes(previous, bytes)) return;
    _memory[key] = bytes;
    final dir = _directory;
    if (dir == null) return;
    await dir.create(recursive: true);
    await File('${dir.path}/$key.img').writeAsBytes(bytes, flush: true);
  }

  /// Writes [bytes] to a file whose name changes with the content, so media
  /// session consumers notice the update. Returns its URI.
  Future<Uri?> exportForNotification(Uint8List bytes) async {
    final dir = _directory;
    if (dir == null) return null;
    final out = Directory('${dir.path}/now_playing');
    await out.create(recursive: true);
    final name = 'art_${_hash(bytes).toRadixString(16)}.img';
    final file = File('${out.path}/$name');
    if (!await file.exists()) {
      await for (final old in out.list()) {
        if (old is File) await old.delete();
      }
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.uri;
  }

  static int _hash(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
