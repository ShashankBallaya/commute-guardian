class Line {
  const Line({
    required this.id,
    required this.name,
    required this.shortName,
    required this.stationIds,
    this.platforms = const {},
    this.lowFrequency = false,
  });

  final String id;

  /// Human label for logs and pickers, e.g. `Central Main: CSMT - Kalyan`.
  final String name;

  /// How the line is SPOKEN, e.g. `Central`. [name] is unusable in an
  /// announcement ("change to the Central Main: CSMT - Kalyan line").
  final String shortName;

  /// Ordered station ids, direction matters.
  final List<String> stationIds;

  /// Which platform to walk to when changing ONTO this line, by station id and
  /// then by the END OF THE LINE the rider is travelling toward, e.g.
  /// `{'dadar_western': {'churchgate': '2 or 4', 'dahanu_road': '1 or 3'}}`.
  ///
  /// THE DIRECTION KEY IS NOT OPTIONAL, and Dadar is why. Thane managed without
  /// one because Trans Harbour only leaves Thane one way. The Western line at
  /// Dadar is platform 1 or 3 going north and 2 or 4 going south, so a single
  /// key per station would have to pick one and be wrong half the time. The key
  /// is what [JourneyPlanner] already computes to say "towards Churchgate".
  ///
  /// Sparse: an interchange with no entry still announces the line change, just
  /// without the platform sentence. Curated from the ground in
  /// `tool/build_stations.py`, never from OSM.
  final Map<String, Map<String, String>> platforms;

  /// The platform to board at [stationId] heading toward [towardsStationId], or
  /// null when nothing has been confirmed for that station or that direction.
  String? platformAt(String stationId, {required String towardsStationId}) =>
      platforms[stationId]?[towardsStationId];

  /// Roughly one train an hour (the Diva MEMU shuttles). The planner routes over
  /// these only when a station is unreachable without them.
  final bool lowFrequency;

  factory Line.fromJson(Map<String, dynamic> json) => Line(
    id: json['id'] as String,
    name: json['name'] as String,
    shortName: json['shortName'] as String,
    stationIds: (json['stationIds'] as List).cast<String>(),
    platforms: {
      for (final entry in (json['platforms'] as Map).entries)
        entry.key as String: (entry.value as Map).cast<String, String>(),
    },
    lowFrequency: json['lowFrequency'] as bool? ?? false,
  );
}
