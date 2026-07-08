import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/line.dart';
import '../models/station.dart';

/// Loads the bundled Central Main line station/line data.
class StationRepository {
  StationRepository._({required this.stationsById, required this.linesById});

  final Map<String, Station> stationsById;
  final Map<String, Line> linesById;

  static const _assetPath = 'assets/stations/central_main_line.json';

  static Future<StationRepository> load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final stations = (json['stations'] as List)
        .cast<Map<String, dynamic>>()
        .map(Station.fromJson);
    final lines =
        (json['lines'] as List).cast<Map<String, dynamic>>().map(Line.fromJson);

    return StationRepository._(
      stationsById: {for (final s in stations) s.id: s},
      linesById: {for (final l in lines) l.id: l},
    );
  }

  Station station(String id) {
    final station = stationsById[id];
    if (station == null) {
      throw ArgumentError('Unknown station id: $id');
    }
    return station;
  }

  /// Ordered stations for [lineId] between [fromId] and [toId] inclusive,
  /// in whichever direction they appear on the line.
  List<Station> segment(String lineId, String fromId, String toId) {
    final line = linesById[lineId];
    if (line == null) {
      throw ArgumentError('Unknown line id: $lineId');
    }

    final fromIndex = line.stationIds.indexOf(fromId);
    final toIndex = line.stationIds.indexOf(toId);
    if (fromIndex == -1 || toIndex == -1) {
      throw ArgumentError('$fromId or $toId not found on line $lineId');
    }

    final ids = fromIndex <= toIndex
        ? line.stationIds.sublist(fromIndex, toIndex + 1)
        : line.stationIds.sublist(toIndex, fromIndex + 1).reversed.toList();

    return ids.map(station).toList();
  }
}
