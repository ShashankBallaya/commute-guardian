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
