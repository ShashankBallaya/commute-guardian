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
  JourneyPlanner({
    required this.stationsById,
    required this.linesById,
    this.throughServices = const [],
  });

  final Map<String, Station> stationsById;
  final Map<String, Line> linesById;

  /// Pairs of line ids one physical train continues across (the Kasara branch
  /// onto the Central trunk at Kalyan). Crossing between them is free in the
  /// search and never announced. Declared in the station data, NOT inferred:
  /// inferring it from the shared "Central" short name silently merged the
  /// Kasara and Karjat branches too, and no train runs branch to branch.
  final List<List<String>> throughServices;

  late final Set<String> _throughKeys = {
    for (final pair in throughServices) _pairKey(pair[0], pair[1]),
  };

  static String _pairKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  /// Whether riding from [lineId] onto [otherLineId] is the same physical train.
  bool _runsThrough(String lineId, String otherLineId) =>
      lineId == otherLineId ||
      _throughKeys.contains(_pairKey(lineId, otherLineId));

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

  /// Breadth-first search over the network, expanded one CHANGE OF TRAIN at a
  /// time rather than one station at a time, so the first route to reach the
  /// destination has by construction the fewest changes. Among routes with the
  /// same number of changes, the shortest ride wins.
  List<_Leg>? _findLegs(String originId, String destinationId) {
    var frontier = <List<_Leg>>[
      for (final lineId in _linesThrough(originId))
        [_Leg(lineId: lineId, fromId: originId, toId: originId)],
    ];
    // Boarding a given line at a given station is worth doing once: arriving
    // there again with more changes behind us can never be better.
    final seen = <String>{
      for (final lineId in _linesThrough(originId)) '$originId@$lineId',
    };

    while (frontier.isNotEmpty) {
      // Everywhere reachable without getting off the train.
      final reached = <List<_Leg>>[];
      for (final route in frontier) {
        reached.addAll(_rideOut(route, seen));
      }

      // Done if any of them is the destination. Take the shortest, since they all
      // cost the same number of changes.
      final arrivals =
          reached.where((r) => r.last.toId == destinationId).toList();
      if (arrivals.isNotEmpty) {
        arrivals.sort(
          (a, b) => _stationsTravelled(a).compareTo(_stationsTravelled(b)),
        );
        return arrivals.first;
      }

      // Not reachable on this many changes, so change trains once more, wherever
      // a change is possible, and search again.
      final next = <List<_Leg>>[];
      for (final route in reached) {
        final leg = route.last;
        for (final lineId in _linesThrough(leg.toId)) {
          if (_runsThrough(lineId, leg.lineId)) continue;
          if (!seen.add('${leg.toId}@$lineId')) continue;
          next.add([
            ...route,
            _Leg(lineId: lineId, fromId: leg.toId, toId: leg.toId),
          ]);
        }
      }
      frontier = next;
    }

    return null;
  }

  /// Every station [route] reaches WITHOUT the rider changing train.
  ///
  /// That is not the same as "without leaving the current line". A Kasara train
  /// runs through Kalyan and carries on down the trunk to CSMT while the rider
  /// sits still, so this also follows any line declared as through-running with
  /// the current one, at no cost. That is what makes Shahad to Dombivli come out
  /// as the one train it actually is. Note the through hop only fires at
  /// stations the current leg rides THROUGH, never back at the leg's own start,
  /// which is what stops Kasara -> trunk -> Karjat chaining into a phantom
  /// three-line "one train" at Kalyan.
  List<List<_Leg>> _rideOut(List<_Leg> route, Set<String> seen) {
    final reached = <List<_Leg>>[];
    final pending = <List<_Leg>>[route];

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final leg = current.last;

      for (final stopId in linesById[leg.lineId]!.stationIds) {
        if (stopId == leg.fromId) continue;
        final extended = [
          ...current.sublist(0, current.length - 1),
          leg.copyWith(toId: stopId),
        ];
        reached.add(extended);

        // The train carries on across a declared through junction.
        for (final lineId in _linesThrough(stopId)) {
          if (lineId == leg.lineId) continue;
          if (!_runsThrough(lineId, leg.lineId)) continue;
          if (!seen.add('$stopId@$lineId')) continue;
          pending.add([
            ...extended,
            _Leg(lineId: lineId, fromId: stopId, toId: stopId),
          ]);
        }
      }
    }

    return reached;
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

    // An interchange is where one leg hands over to the next AND that means
    // getting off a train. Crossing a declared through junction (Kasara onto
    // the trunk at Kalyan) is a leg boundary but not a change: the train runs
    // through and the rider stays put. Announcing "get off at Kalyan" there would
    // put them on a platform for no reason.
    final interchanges = <Interchange>[];
    for (var i = 1; i < legs.length; i++) {
      if (_runsThrough(legs[i].lineId, legs[i - 1].lineId)) continue;
      final onto = linesById[legs[i].lineId]!;
      final from = linesById[legs[i - 1].lineId]!;
      interchanges.add(
        Interchange(
          stationId: legs[i].fromId,
          fromLineId: from.id,
          toLineId: onto.id,
          toLineShortName: onto.shortName,
          towardsStationName:
              stationsById[_directionTerminalId(legs[i])]!.name,
          isSameNamedService: onto.shortName == from.shortName,
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

  /// The station the onward leg's line ends at in its direction of travel, e.g.
  /// Karjat for a leg riding the Karjat branch away from Kalyan. This is how a
  /// train change is described when the line name alone cannot disambiguate it
  /// ("change to Central" while already on Central says nothing; "board the
  /// train towards Karjat" does).
  String _directionTerminalId(_Leg leg) {
    final ids = linesById[leg.lineId]!.stationIds;
    final from = ids.indexOf(leg.fromId);
    final to = ids.indexOf(leg.toId);
    return to >= from ? ids.last : ids.first;
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
