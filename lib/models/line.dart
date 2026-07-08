class Line {
  const Line({
    required this.id,
    required this.name,
    required this.stationIds,
  });

  final String id;
  final String name;

  /// Ordered station ids, direction matters.
  final List<String> stationIds;

  factory Line.fromJson(Map<String, dynamic> json) => Line(
        id: json['id'] as String,
        name: json['name'] as String,
        stationIds: (json['stationIds'] as List).cast<String>(),
      );
}
