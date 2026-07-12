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

  /// Which platform to walk to when changing ONTO this line, by station id, e.g.
  /// `{'thane': '9, 10, or 10 A'}`. Sparse: an interchange with no entry still
  /// announces the line change, just without the platform sentence.
  final Map<String, String> platforms;

  /// Roughly one train an hour (the Diva MEMU shuttles). The planner routes over
  /// these only when a station is unreachable without them.
  final bool lowFrequency;

  factory Line.fromJson(Map<String, dynamic> json) => Line(
        id: json['id'] as String,
        name: json['name'] as String,
        shortName: json['shortName'] as String,
        stationIds: (json['stationIds'] as List).cast<String>(),
        platforms: (json['platforms'] as Map).cast<String, String>(),
        lowFrequency: json['lowFrequency'] as bool? ?? false,
      );
}
