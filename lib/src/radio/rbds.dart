/// RBDS (North America) PI code -> call sign, per NRSC-4-B Annex D.
library;

const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// Call signs that predate the four-letter scheme get fixed PI codes.
const _threeLetter = <int, String>{
  0x9950: 'KEX', 0x9951: 'KFH', 0x9952: 'KFI', 0x9953: 'KGA', 0x9954: 'KGO',
  0x9955: 'KGU', 0x9956: 'KGW', 0x9957: 'KGY', 0x9958: 'KID', 0x9959: 'KIT',
  0x995A: 'KJR', 0x995B: 'KLO', 0x995C: 'KLZ', 0x995D: 'KMA', 0x995E: 'KMJ',
  0x995F: 'KNX', 0x9960: 'KOA', 0x9964: 'KQV', 0x9965: 'KSL', 0x9966: 'KUJ',
  0x9967: 'KVI', 0x9968: 'KWG', 0x996B: 'KYW', 0x996D: 'WBZ', 0x996E: 'WDZ',
  0x996F: 'WEW', 0x9971: 'WGL', 0x9972: 'WGN', 0x9973: 'WGR', 0x9975: 'WHA',
  0x9976: 'WHB', 0x9977: 'WHK', 0x9978: 'WHO', 0x997A: 'WIP', 0x997B: 'WJR',
  0x997C: 'WKY', 0x997D: 'WLS', 0x997E: 'WLW', 0x9981: 'WOC', 0x9983: 'WOL',
  0x9984: 'WOR', 0x9988: 'WWJ', 0x9989: 'WWL', 0x9990: 'KDB', 0x9991: 'KGB',
  0x9992: 'KOY', 0x9993: 'KPQ', 0x9994: 'KSD', 0x9995: 'KUT', 0x9996: 'KXL',
  0x9997: 'KXO', 0x9999: 'WBT', 0x999A: 'WGH', 0x999B: 'WGY', 0x999C: 'WHP',
  0x999D: 'WIL', 0x999E: 'WMC', 0x999F: 'WMT', 0x99A0: 'WOI', 0x99A1: 'WOW',
  0x99A2: 'WRR', 0x99A3: 'WSB', 0x99A4: 'WSM', 0x99A5: 'KBW', 0x99A6: 'KCY',
  0x99A7: 'KDF', 0x99AA: 'KHQ', 0x99AB: 'KOB', 0x99B3: 'WIS', 0x99B4: 'WJW',
  0x99B5: 'WJZ', 0x99B9: 'WRC',
};

/// Returns the call sign encoded in [pi], or null when the code is not a
/// call-sign PI (e.g. a European or nationally linked code).
String? callSignFromPi(int pi) {
  var code = pi & 0xFFFF;
  // "AFxy" codes stand for "x000"-style national networks; "Axyz" codes are a
  // compressed form of "x0yz".
  if ((code & 0xFFF0) == 0xAFA0 && (code & 0xF) >= 1 && (code & 0xF) <= 9) {
    code = (code & 0xF) << 12;
  } else if ((code & 0xF000) == 0xA000) {
    code = ((code & 0x0F00) << 4) | (code & 0x00FF);
  }

  final three = _threeLetter[code];
  if (three != null) return three;

  String fourLetter(String prefix, int value) {
    final a = value ~/ 676;
    final b = (value % 676) ~/ 26;
    final c = value % 26;
    return '$prefix${_letters[a]}${_letters[b]}${_letters[c]}';
  }

  if (code >= 0x1000 && code <= 0x54A7) return fourLetter('K', code - 0x1000);
  if (code >= 0x54A8 && code <= 0x994F) return fourLetter('W', code - 0x54A8);
  return null;
}

/// PI code for a North American call sign, the inverse of [callSignFromPi].
int? piFromCallSign(String call) {
  final upper = call.trim().toUpperCase();
  for (final entry in _threeLetter.entries) {
    if (entry.value == upper) return entry.key;
  }
  if (upper.length != 4) return null;
  final prefix = upper[0];
  if (prefix != 'K' && prefix != 'W') return null;
  var value = 0;
  for (var i = 1; i < 4; i++) {
    final letter = upper.codeUnitAt(i) - 0x41;
    if (letter < 0 || letter > 25) return null;
    value = value * 26 + letter;
  }
  final code = prefix == 'K' ? 0x1000 + value : 0x54A8 + value;
  if (prefix == 'K' && code > 0x54A7) return null;
  if (prefix == 'W' && code > 0x994F) return null;
  return code;
}

/// Pulls a K/W call sign out of a station name ("KEXP", "90.3 KEXP-FM").
int? piFromStationText(String? text) {
  if (text == null) return null;
  final match = RegExp(r'\b([KW][A-Z]{2,3})\b').firstMatch(text.toUpperCase());
  if (match == null) return null;
  return piFromCallSign(match.group(1)!);
}
