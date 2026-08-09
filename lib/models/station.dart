import 'dart:math' as math;

import 'app_settings.dart';

/// One thing the app says out loud, in each language it can say it in.
///
/// Exists because a spoken name has to survive the trip from the planner to
/// the announcement without the planner knowing what language the ride will
/// be spoken in. The planner runs once, at Start, and resolves names from the
/// station repository; the language can change under a ride (Settings is
/// reachable mid-ride). Carrying all three is smaller than carrying the
/// repository, and it cannot go stale.
class SpokenName {
  const SpokenName({required this.en, required this.hi, required this.mr});

  /// The same word in all three languages: line names and other proper nouns
  /// that have no Devanagari form in the data.
  const SpokenName.same(String word) : en = word, hi = word, mr = word;

  final String en;
  final String hi;
  final String mr;

  String inLanguage(AppLanguage language) => switch (language) {
    AppLanguage.english => en,
    AppLanguage.hindi => hi,
    AppLanguage.marathi => mr,
  };
}

class Station {
  const Station({
    required this.id,
    required this.code,
    required this.name,
    required this.nameHi,
    required this.nameMr,
    required this.lat,
    required this.lng,
    required this.radiusM,
  });

  final String id;

  /// Indian Railways station code, e.g. `KYN` for Kalyan. Unique across the
  /// network, unlike the name: Dadar Central (`DR`) and Dadar Western (`DDR`)
  /// share a name but are separate stations. Two entries carrying the same code
  /// therefore means one station has been split in two by mistake.
  final String code;

  final String name;
  final String nameHi;
  final String nameMr;
  final double lat;
  final double lng;
  final int radiusM;

  /// This station's name in the language the ride is being spoken in.
  ///
  /// EVERY SPOKEN SENTENCE GOES THROUGH HERE. A Hindi template wrapped around
  /// the English name is a mid-sentence language switch, which is the exact
  /// thing ADR 0001 refuses to do with clips, and it sounds no better on the
  /// device TTS floor. The screens keep using [name]: this is about what comes
  /// out of the earphones, not what is drawn.
  String nameIn(AppLanguage language) => switch (language) {
    AppLanguage.english => name,
    AppLanguage.hindi => nameHi,
    AppLanguage.marathi => nameMr,
  };

  /// All three names together, for the announcement copy that is built at
  /// plan time and spoken later. See [SpokenName].
  SpokenName get spokenName => SpokenName(en: name, hi: nameHi, mr: nameMr);

  /// Whether this station answers to [query], matched against every name it is
  /// known by and its code, so a commuter can type "Kalyan", "कल्याण" or "KYN".
  /// An empty query matches everything, which is the unfiltered list.
  ///
  /// Devanagari is caseless, so lowercasing it is a no-op and costs nothing.
  /// Matching is substring, not fuzzy: a typo finds nothing.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        nameHi.toLowerCase().contains(q) ||
        nameMr.toLowerCase().contains(q) ||
        code.toLowerCase().contains(q);
  }

  /// Great-circle distance in metres from this station to a fix (haversine).
  ///
  /// Lives on the station because three engines now ask the same question of
  /// one, and a per-engine copy of this formula is the drift this project has
  /// been bitten by before: the day the radius test is tuned in one copy, the
  /// others keep announcing on the old one.
  double distanceM(double lat, double lng) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(lat - this.lat);
    final dLng = _toRad(lng - this.lng);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(this.lat)) *
            math.cos(_toRad(lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Whether a fix lies inside this station's own fence.
  bool contains(double lat, double lng) => distanceM(lat, lng) <= radiusM;

  static double _toRad(double deg) => deg * math.pi / 180.0;

  factory Station.fromJson(Map<String, dynamic> json) => Station(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    nameHi: json['nameHi'] as String,
    nameMr: json['nameMr'] as String,
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    radiusM: json['radiusM'] as int,
  );
}
