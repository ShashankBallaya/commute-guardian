import '../models/journey.dart';
import '../models/line.dart';
import '../models/station.dart';

/// Plans a [Journey] between two stations over the real line network.
///
/// This replaced the hardcoded Phase 0 ride constants. Given only an origin and a
/// destination it works out which trains to take, where to change, which stations
/// will be passed on the way, and where the overshoot safety net sits, all of which
/// used to be hand-authored per ride.
///
/// Riders care far more about not changing trains than about a stop or two of
/// distance (a change at a Mumbai interchange means fighting through a crowded
/// footbridge with luggage), so the search minimizes CHANGES first and only then
/// stations travelled.
class JourneyPlanner {
  JourneyPlanner({required this.stationsById, required this.linesById});

  final Map<String, Station> stationsById;
  final Map<String, Line> linesById;

  Journey plan({required String originId, required String destinationId}) {
    final origin = stationsById[originId];
    final destination = stationsById[destinationId];
    if (origin == null) {
      throw ArgumentError('Unknown origin station: $originId');
    }
    if (destination == null) {
      throw ArgumentError('Unknown destination station: $destinationId');
    }
    if (originId == destinationId) {
      throw ArgumentError('Origin and destination are the same: $originId');
    }

    final legs = _findLegs(originId, destinationId);
    if (legs == null) {
      throw ArgumentError('No route from $originId to $destinationId');
    }

    return _buildJourney(legs, originId, destinationId);
  }

  /// Breadth-first search over the network, expanded one CHANGE at a time rather
  /// than one station at a time, so the first route that reaches the destination
  /// is by construction the one with the fewest changes. Within a change count,
  /// the frontier is ordered by stations travelled, so the shortest of the
  /// equally-convenient routes wins.
  List<_Leg>? _findLegs(String originId, String destinationId) {
    // Routes under construction, shortest-first. Each is the sequence of legs
    // taken so far; the last leg's `to` is where we currently stand.
    var frontier = <List<_Leg>>[
      for (final lineId in _linesThrough(originId))
        [_Leg(lineId: lineId, fromId: originId, toId: originId)],
    ];
    // A station is worth boarding a given line at only once: reaching it again on
    // the same line with more changes behind us can never be better.
    final seen = <String>{
      for (final lineId in _linesThrough(originId)) '$originId@$lineId',
    };

    while (frontier.isNotEmpty) {
      // Every station reachable on the current lines WITHOUT changing again. If
      // the destination is among them we are done, at the current change count.
      final reached = <List<_Leg>>[];
      for (final route in frontier) {
        final leg = route.last;
        for (final stopId in linesById[leg.lineId]!.stationIds) {
          if (stopId == leg.fromId) continue;
          final extended = [
            ...route.sublist(0, route.length - 1),
            leg.copyWith(toId: stopId),
          ];
          if (stopId == destinationId) return extended;
          reached.add(extended);
        }
      }

      // Nothing reached the destination on this many changes, so change trains
      // once more, everywhere a change is possible, and search again.
      final next = <List<_Leg>>[];
      for (final route in reached) {
        final leg = route.last;
        for (final lineId in _linesThrough(leg.toId)) {
          if (lineId == leg.lineId) continue;
          if (!seen.add('${leg.toId}@$lineId')) continue;
          next.add([
            ...route,
            _Leg(lineId: lineId, fromId: leg.toId, toId: leg.toId),
          ]);
        }
      }

      // Fewest stations travelled first, so that among routes with the same
      // number of changes we prefer the shorter ride.
      next.sort((a, b) => _stationsTravelled(a).compareTo(_stationsTravelled(b)));
      frontier = next;
    }

    return null;
  }

  Journey _buildJourney(
    List<_Leg> legs,
    String originId,
    String destinationId,
  ) {
    // Flatten the legs into one chain. Each leg after the first starts at the
    // station the previous one ended on, so drop that shared station.
    final chainIds = <String>[];
    for (final leg in legs) {
      final ids = _segmentIds(leg.lineId, leg.fromId, leg.toId);
      chainIds.addAll(chainIds.isEmpty ? ids : ids.skip(1));
    }

    // The interchange is the station where one leg hands over to the next.
    final interchanges = <Interchange>[];
    for (var i = 1; i < legs.length; i++) {
      final onto = linesById[legs[i].lineId]!;
      interchanges.add(
        Interchange(
          stationId: legs[i].fromId,
          fromLineId: legs[i - 1].lineId,
          toLineId: onto.id,
          toLineShortName: onto.shortName,
          platform: onto.platforms[legs[i].fromId],
        ),
      );
    }

    // Safety net: carry the chain one station PAST the destination, so a rider who
    // sleeps through the alight still gets a "you have passed your stop" warning.
    // A destination at the end of the line has nothing past it to warn from.
    final overshootId = _stationPast(legs.last, destinationId);
    if (overshootId != null) {
      chainIds.add(overshootId);
    }

    return Journey(
      chain: [for (final id in chainIds) stationsById[id]!],
      originStationId: originId,
      destinationStationId: destinationId,
      overshootStationId: overshootId,
      interchanges: interchanges,
    );
  }

  /// The next station after [destinationId] on the final leg's line, continuing in
  /// the direction of travel. Null at the end of the line.
  String? _stationPast(_Leg finalLeg, String destinationId) {
    final ids = linesById[finalLeg.lineId]!.stationIds;
    final from = ids.indexOf(finalLeg.fromId);
    final to = ids.indexOf(destinationId);
    final step = to >= from ? 1 : -1;
    final past = to + step;
    return past >= 0 && past < ids.length ? ids[past] : null;
  }

  /// Station ids on [lineId] from [fromId] to [toId] inclusive, in travel order.
  /// A line is stored in one direction; riding it the other way is the reverse.
  List<String> _segmentIds(String lineId, String fromId, String toId) {
    final ids = linesById[lineId]!.stationIds;
    final from = ids.indexOf(fromId);
    final to = ids.indexOf(toId);
    return from <= to
        ? ids.sublist(from, to + 1)
        : ids.sublist(to, from + 1).reversed.toList();
  }

  int _stationsTravelled(List<_Leg> legs) => legs.fold(
        0,
        (total, leg) => total + _segmentIds(leg.lineId, leg.fromId, leg.toId).length,
      );

  Iterable<String> _linesThrough(String stationId) => linesById.values
      .where((line) => line.stationIds.contains(stationId))
      .map((line) => line.id);
}

/// A continuous ride on one line, from boarding it to leaving it.
class _Leg {
  const _Leg({
    required this.lineId,
    required this.fromId,
    required this.toId,
  });

  final String lineId;
  final String fromId;
  final String toId;

  _Leg copyWith({String? toId}) =>
      _Leg(lineId: lineId, fromId: fromId, toId: toId ?? this.toId);
}
