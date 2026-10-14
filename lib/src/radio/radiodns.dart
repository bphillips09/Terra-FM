import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'band_plan.dart';

/// A RadioDNS query built from broadcast parameters.
///
/// FM follows the [station logo walkthrough](https://radiodns.org/campaigns/project-logo/walkthrough-finding-radio-station-logos/)
/// and ETSI TS 103 270: CNAME the FQDN, SRV `_radiospi._tcp` / `_radioepg._tcp`,
/// then read `/radiodns/spi/3.1/SI.xml`. HD uses the same steps with the
/// IBOC FQDN (`<facility>.<country>.hd.radiodns.org`).
class RadioDnsQuery {
  const RadioDnsQuery({required this.fqdn, required this.bearer});

  /// `<frequency>.<pi>.<gcc>.fm.radiodns.org` or `<tx>.<cc>.hd.radiodns.org`.
  final String fqdn;

  /// `fm:<gcc>.<pi>.<frequency>` or `hd:<cc>.<tx>`.
  final String bearer;
}

/// Thrown when DNS or HTTP fails because the network is unreachable.
class RadioDnsOffline implements Exception {
  const RadioDnsOffline();
}

class RadioDns {
  RadioDns({RadioDnsNet? net}) : _net = net ?? _IoRadioDnsNet();

  final RadioDnsNet _net;
  final _srv = <String, _Srv?>{};
  final _si = <String, String?>{};

  void close() => _net.close();

  /// Drops cached SRV and SI documents. Call once per band scan.
  void beginPass() {
    _srv.clear();
    _si.clear();
  }

  /// Queries for one station. HD facility id is tried before the FM PI.
  /// [pi] is the RDS PI when the broadcast sent one; otherwise a call-sign PI.
  static List<RadioDnsQuery> queries({
    required int frequencyHz,
    required BandPlan band,
    int? pi,
    int? facilityId,
    String? countryCode,
  }) {
    final out = <RadioDnsQuery>[];
    final cc = ibocCountryCode(countryCode, band);
    if (facilityId != null && facilityId > 0 && cc != null) {
      final tx = facilityId.toRadixString(16).padLeft(5, '0');
      out.add(RadioDnsQuery(fqdn: '$tx.$cc.hd.radiodns.org', bearer: 'hd:$cc.$tx'));
    }
    if (pi != null) {
      final piHex = (pi & 0xFFFF).toRadixString(16).padLeft(4, '0');
      final freq = fmFrequencyCode(frequencyHz);
      for (final ecc in fmEccCandidates(countryCode: countryCode, band: band)) {
        final gcc = '${((pi >> 12) & 0xF).toRadixString(16)}$ecc';
        out.add(
          RadioDnsQuery(fqdn: '$freq.$piHex.$gcc.fm.radiodns.org', bearer: 'fm:$gcc.$piHex.$freq'),
        );
      }
    }
    return out;
  }

  /// Image bytes, or null when this station has no RadioDNS logo.
  /// Throws [RadioDnsOffline] when the network itself fails.
  Future<Uint8List?> logo(List<RadioDnsQuery> queries) async {
    for (final query in queries) {
      final auth = await _authoritative(query.fqdn);
      if (auth == null) continue;
      final si = await _serviceInformation(auth);
      if (si == null) continue;
      final url = logoUrl(si.text, query.bearer, si.uri);
      if (url == null) continue;
      final image = await _image(Uri.parse(url));
      if (image != null) return image;
    }
    return null;
  }

  Future<String?> _authoritative(String fqdn) async {
    final answers = await _net.lookup(fqdn, 5);
    if (answers == null) throw const RadioDnsOffline();
    String? target;
    for (final answer in answers) {
      if (answer.type == 5 && answer.data.isNotEmpty) target = answer.data;
    }
    if (target == null) return null;
    return _host(target);
  }

  Future<_Document?> _serviceInformation(String authoritative) async {
    if (_si.containsKey(authoritative)) {
      final cached = _si[authoritative];
      if (cached == null) return null;
      final srv = _srv[authoritative];
      if (srv == null) return null;
      return _Document(text: cached, uri: _siUri(srv));
    }
    final srv = await _srvRecord(authoritative);
    if (srv == null) {
      _si[authoritative] = null;
      return null;
    }
    final uri = _siUri(srv);
    final response = await _net.get(uri, maxBytes: 4 * 1024 * 1024);
    if (response == null) throw const RadioDnsOffline();
    if (response.status != 200 || response.body.isEmpty) {
      _si[authoritative] = null;
      return null;
    }
    final text = utf8.decode(response.body, allowMalformed: true);
    _si[authoritative] = text;
    return _Document(text: text, uri: uri);
  }

  Future<_Srv?> _srvRecord(String authoritative) async {
    if (_srv.containsKey(authoritative)) return _srv[authoritative];
    _Srv? found;
    for (final https in [true, false]) {
      final name = '${https ? '_radiospi' : '_radioepg'}._tcp.$authoritative';
      final answers = await _net.lookup(name, 33);
      if (answers == null) throw const RadioDnsOffline();
      final records = [
        for (final answer in answers)
          if (answer.type == 33) _parseSrv(answer.data, https: https),
      ].whereType<_Srv>().toList()..sort((a, b) => a.priority.compareTo(b.priority));
      if (records.isNotEmpty) {
        found = records.first;
        break;
      }
    }
    _srv[authoritative] = found;
    return found;
  }

  Future<Uint8List?> _image(Uri url) async {
    final response = await _net.get(url, maxBytes: 2 * 1024 * 1024);
    if (response == null) throw const RadioDnsOffline();
    if (response.status != 200) return null;
    return isLogoImage(response.body) ? response.body : null;
  }
}

/// Five-digit FM frequency in units of 10 kHz. 95.8 MHz → `09580`.
String fmFrequencyCode(int frequencyHz) => (frequencyHz / 10000).round().toString().padLeft(5, '0');

/// RDS extended country codes to try, most likely first.
///
/// The broadcast ECC is not decoded. USA `a0`, Germany `e0` and the UK `e1`
/// are the codes RadioDNS documents; Canada is `a1`.
List<String> fmEccCandidates({String? countryCode, required BandPlan band}) {
  final fromCountry = switch (countryCode?.trim().toUpperCase()) {
    'US' || 'USA' => 'a0',
    'CA' || 'CAN' => 'a1',
    'DE' || 'DEU' => 'e0',
    'GB' || 'UK' || 'GBR' => 'e1',
    _ => null,
  };
  if (fromCountry != null) return [fromCountry];
  return switch (band) {
    BandPlan.northAmerica || BandPlan.americas => const ['a0', 'a1'],
    BandPlan.europe => const ['e0', 'e1'],
    BandPlan.japan => const ['e2'],
  };
}

/// IBOC country code. TS 103 270 gives the United States as `292`.
String? ibocCountryCode(String? countryCode, BandPlan band) {
  final text = countryCode?.trim().toLowerCase().replaceFirst(RegExp(r'^0x'), '');
  if (text == 'us' || text == 'usa' || text == '292') return '292';
  if (text != null && RegExp(r'^[0-9a-f]{3}$').hasMatch(text)) return text;
  if ((text == null || text.isEmpty) && (band == BandPlan.northAmerica || band == BandPlan.americas)) {
    return '292';
  }
  return null;
}

/// Logo URL inside an SI document for [bearer], or a wildcard FM bearer.
String? logoUrl(String si, String bearer, Uri base) {
  final wanted = bearer.toLowerCase();
  final services = RegExp(r'<service\b[^>]*>[\s\S]*?</service>', caseSensitive: false);
  for (final service in services.allMatches(si)) {
    final body = service.group(0)!;
    if (!_serviceHasBearer(body, wanted)) continue;
    final chosen = _chooseLogo(body);
    if (chosen == null) continue;
    final resolved = base.resolve(chosen);
    if (resolved.hasScheme) return resolved.toString();
  }
  return null;
}

bool isLogoImage(Uint8List bytes) {
  if (bytes.length < 8) return false;
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
  return bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;
}

bool _serviceHasBearer(String service, String bearer) {
  final ids = RegExp(r'''\bid\s*=\s*["']([^"']+)["']''', caseSensitive: false);
  for (final match in ids.allMatches(service)) {
    final id = match.group(1)!.toLowerCase();
    if (id == bearer) return true;
    if (bearer.startsWith('fm:') && id.endsWith('.*')) {
      final prefix = id.substring(0, id.length - 1);
      if (bearer.startsWith(prefix)) return true;
    }
    if (bearer.startsWith('hd:') && id.startsWith('$bearer.')) return true;
    if (bearer.startsWith('fm:') && id.startsWith('fm:')) {
      final a = id.split('.');
      final b = bearer.split('.');
      if (a.length == 3 && b.length == 3 && a[0] == b[0] && a[1] == b[1]) {
        final left = int.tryParse(a[2]);
        final right = int.tryParse(b[2]);
        if (left != null && left == right) return true;
      }
    }
  }
  return false;
}

String? _chooseLogo(String service) {
  final tags = RegExp(r'<multimedia\b([^>]*)/?>', caseSensitive: false);
  final attrs = RegExp('''([A-Za-z]+)\\s*=\\s*["']([^"']*)["']''');
  String? bestUrl;
  var bestScore = -1;
  for (final tag in tags.allMatches(service)) {
    final map = <String, String>{};
    for (final attr in attrs.allMatches(tag.group(1)!)) {
      map[attr.group(1)!.toLowerCase()] = attr.group(2)!;
    }
    final url = map['url'];
    if (url == null || url.isEmpty || !_looksLikeLogo(map, url)) continue;
    final width = int.tryParse(map['width'] ?? '') ?? 0;
    final height = int.tryParse(map['height'] ?? '') ?? 0;
    final score = _logoScore(width, height, map['type']?.toLowerCase() ?? '');
    if (score > bestScore) {
      bestScore = score;
      bestUrl = url;
    }
  }
  return bestUrl;
}

bool _looksLikeLogo(Map<String, String> attrs, String url) {
  final type = attrs['type']?.toLowerCase() ?? '';
  if (type.isNotEmpty && !type.contains('logo')) return false;
  final mime = attrs['mimevalue']?.toLowerCase() ?? '';
  if (mime.startsWith('image/')) return true;
  return RegExp(r'\.(png|jpe?g|webp|gif)(\?|$)', caseSensitive: false).hasMatch(url);
}

int _logoScore(int width, int height, String type) {
  final size = width > height ? width : height;
  final square = width > 0 && width == height;
  var score = square || type == 'logo_colour_square' ? 100000 : 0;
  if (size >= 128 && size <= 800) {
    score += 10000 + size;
  } else if (size > 800) {
    score += 5000 - (size - 800);
  } else {
    score += size;
  }
  return score;
}

class DnsAnswer {
  const DnsAnswer({required this.type, required this.data});
  final int type;
  final String data;
}

class RadioDnsResponse {
  const RadioDnsResponse({required this.status, required this.body});
  final int status;
  final Uint8List body;
}

/// DNS and HTTP. A null result means the network could not be reached.
abstract interface class RadioDnsNet {
  Future<List<DnsAnswer>?> lookup(String name, int type);
  Future<RadioDnsResponse?> get(Uri uri, {required int maxBytes});
  void close();
}

class _Document {
  const _Document({required this.text, required this.uri});
  final String text;
  final Uri uri;
}

class _Srv {
  const _Srv({required this.priority, required this.port, required this.host, required this.https});
  final int priority;
  final int port;
  final String host;
  final bool https;
}

_Srv? _parseSrv(String data, {required bool https}) {
  final parts = data.trim().split(RegExp(r'\s+'));
  if (parts.length < 4) return null;
  final priority = int.tryParse(parts[0]);
  final port = int.tryParse(parts[2]);
  final host = _host(parts.sublist(3).join(' '));
  if (priority == null || port == null || host.isEmpty) return null;
  return _Srv(priority: priority, port: port, host: host, https: https || port == 443);
}

String _host(String value) => value.trim().replaceAll(RegExp(r'\.$'), '').toLowerCase();

Uri _siUri(_Srv srv) {
  final scheme = srv.https ? 'https' : 'http';
  final omit = (scheme == 'https' && srv.port == 443) || (scheme == 'http' && srv.port == 80);
  return Uri(scheme: scheme, host: srv.host, port: omit ? null : srv.port, path: '/radiodns/spi/3.1/SI.xml');
}

class _IoRadioDnsNet implements RadioDnsNet {
  HttpClient? _client;
  static const _timeout = Duration(seconds: 8);

  HttpClient get _http {
    final existing = _client;
    if (existing != null) return existing;
    final created = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'TerraFM/0.1';
    return _client = created;
  }

  @override
  Future<List<DnsAnswer>?> lookup(String name, int type) async {
    final uri = Uri.https('cloudflare-dns.com', '/dns-query', {'name': name, 'type': '$type'});
    final response = await get(uri, maxBytes: 256 * 1024, accept: 'application/dns-json');
    if (response == null || response.status != 200) return null;
    try {
      final json = jsonDecode(utf8.decode(response.body)) as Map<String, Object?>;
      final answers = json['Answer'];
      if (answers is! List) return const [];
      return [
        for (final row in answers)
          if (row is Map)
            DnsAnswer(type: (row['type'] as num?)?.toInt() ?? 0, data: '${row['data'] ?? ''}'),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Future<RadioDnsResponse?> get(Uri uri, {required int maxBytes, String? accept}) async {
    final first = await _get(uri, maxBytes: maxBytes, accept: accept);
    if (first != null || uri.scheme != 'http') return first;
    final httpsPort = uri.hasPort && uri.port != 80 ? uri.port : 443;
    return _get(uri.replace(scheme: 'https', port: httpsPort == 443 ? null : httpsPort), maxBytes: maxBytes, accept: accept);
  }

  Future<RadioDnsResponse?> _get(Uri uri, {required int maxBytes, String? accept}) async {
    try {
      final request = await _http.getUrl(uri).timeout(_timeout);
      if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
      final response = await request.close().timeout(_timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        if (builder.length + chunk.length > maxBytes) {
          await response.drain<void>();
          return RadioDnsResponse(status: 200, body: Uint8List(0));
        }
        builder.add(chunk);
      }
      return RadioDnsResponse(status: response.statusCode, body: builder.takeBytes());
    } on Object {
      return null;
    }
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
