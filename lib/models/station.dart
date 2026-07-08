class Station {
  const Station({
    required this.id,
    required this.name,
    required this.nameHi,
    required this.nameMr,
    required this.lat,
    required this.lng,
    required this.radiusM,
  });

  final String id;
  final String name;
  final String nameHi;
  final String nameMr;
  final double lat;
  final double lng;
  final int radiusM;

  factory Station.fromJson(Map<String, dynamic> json) => Station(
        id: json['id'] as String,
        name: json['name'] as String,
        nameHi: json['nameHi'] as String,
        nameMr: json['nameMr'] as String,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        radiusM: json['radiusM'] as int,
      );
}
