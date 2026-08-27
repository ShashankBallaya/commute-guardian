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
    this.walkInterchanges = const [],
    this.endpointOnlyWalkInterchanges = const [],
  });

  final Map<String, Station> stationsById;
  final Map<String, Line> linesById;

  /// Pairs of line ids one physical train continues across (the Kasara branch
  /// onto the Central trunk at Kalyan). Crossing between them is free in the
  /// search and never announced. Declared in the station data, NOT inferred:
  /// inferring it from the shared "Central" short name silently merged the
  /// Kasara and Karjat branches too, and no train runs branch to branch.
  final List<List<String>> throughServices;

  /// Station pairs joined by a foot overbridge that commuters change lines
  /// over: Dadar Central to Dadar Western is THE Mumbai interchange move, and
  /// without it the Central and Western corridors barely connect, sending
  /// Shahad -> Borivali around via the hourly Vasai MEMU. Walking across costs
  /// one change, like any other interchange.
  final List<List<String>> walkInterchanges;

  /// Walk interchanges a rider only uses when they are ALREADY standing at one
  /// end of them, never as a through interchange on a longer journey.
  ///
  /// Parel to Prabhadevi is the only one today, and the reason is a fact about
  /// Mumbai rather than about geometry: both are slow-only halts, and Dadar is
  /// where the fast locals stop. Coming from Churchgate or Mumbai Central,
  /// Prabhadevi arrives one stop BEFORE Dadar Western, so ranking equal-change
  /// routes by stations travelled picked the Parel bridge and saved a single
  /// stop on a slow train by changing where no fast train calls. Reported
  /// 25 Aug 2026 by the owner, who put it plainly: the common thing in Mumbai
  /// is to go to the biggest station, because there you get both fast and slow.
  ///
  /// Standing AT Parel or Prabhadevi is the case this does not touch. Then the
  /// bridge is exactly what a rider uses, so it stays available whenever one of
  /// its two stations is the journey's own origin or destination.
  final List<List<String>> endpointOnlyWalkInterchanges;

  late final Set<String> _throughKeys = {
    for (final pair in throughServices) _pairKey(pair[0], pair[1]),
  };

  late final Map<String, String> _walkPartner = {
    for (final pair in walkInterchanges) ...{
      pair[0]: pair[1],
      pair[1]: pair[0],
    },
  };

  late final Set<String> _endpointOnlyWalkKeys = {
    for (final pair in endpointOnlyWalkInterchanges) _pairKey(pair[0], pair[1]),
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
    // STANDING AT ONE END OF A FOOT OVERBRIDGE, THE OTHER END IS A WALK, NOT A
    // RIDE. A rider at Dadar Central asking for Dadar Western wants to cross
    // the bridge, and there is no train that does it: the planner would send
    // them on a loop through Mahim or Kurla to arrive back where they started.
    // Owner, 25 Aug 2026. The destination picker should not offer it either;
    // this is the safety net under that, not a replacement for it.
    if (_walkPartner[originId] == destinationId) {
      throw ArgumentError(
        'No ride from $originId to $destinationId: they are two sides of one '
        'foot overbridge, so this is a walk rather than a journey.',
      );
    }

    // BOTH HALVES OF A WALK INTERCHANGE ARE THE SAME PLACE TO A RIDER.
    //
    // "Dadar" is one station in a Mumbai head, and two rows in this data: DR on
    // Central and DDR on Western. A rider on a Central train who picks the
    // Western one has asked for a station their train does not call at, and the
    // planner used to answer literally, sending them past Dadar to change at
    // Parel. So the SIDE is the planner's to choose, not the rider's: plan to
    // each half and keep the better route. Reported 25 Aug 2026.
    //
    // The origin needs no such resolution. It comes from GPS rather than from a
    // list, and a rider standing at Dadar Western really is at Dadar Western;
    // walking across is a real first move, and the search now offers it.
    final candidates = <String>[
      destinationId,
      ?_walkPartner[destinationId],
    ].where((id) => id != originId).toList();

    List<_Leg>? best;
    String? bestId;
    for (final candidate in candidates) {
      // An hourly MEMU is not a route anyone would choose, so plan without the
      // low-frequency lines first and fall back to them only when a station is
      // unreachable any other way (Kharbao, Nilaje and friends live on them).
      final legs =
          _findLegs(originId, candidate, allowLowFrequency: false) ??
          _findLegs(originId, candidate, allowLowFrequency: true);
      if (legs == null) continue;
      if (best == null || _isBetter(legs, best)) {
        best = legs;
        bestId = candidate;
      }
    }
    if (best == null || bestId == null) {
      throw ArgumentError('No route from $originId to $destinationId');
    }

    // THE RIDER'S OWN PICK TRAVELS WITH THE PLAN. `bestId` is the platform the
    // train puts them on; `destinationId` is what they tapped, and the two
    // differ across a foot overbridge. Passing only the first is what made the
    // Parel-for-Prabhadevi substitution silent.
    return _buildJourney(best, originId, bestId, destinationId);
  }

  /// Fewer changes wins; a tie goes to the shorter ride. The same order the
  /// search itself uses, applied across the two halves of a walk interchange.
  bool _isBetter(List<_Leg> candidate, List<_Leg> incumbent) {
    if (candidate.length != incumbent.length) {
      return candidate.length < incumbent.length;
    }
    return _stationsTravelled(candidate) < _stationsTravelled(incumbent);
  }

  /// Breadth-first search over the network, expanded one CHANGE OF TRAIN at a
  /// time rather than one station at a time, so the first route to reach the
  /// destination has by construction the fewest changes. Among routes with the
  /// same number of changes, the shortest ride wins.
  List<_Leg>? _findLegs(
    String originId,
    String destinationId, {
    required bool allowLowFrequency,
  }) {
    var frontier = <List<_Leg>>[
      for (final lineId in _linesThrough(originId, allowLowFrequency))
        [_Leg(lineId: lineId, fromId: originId, toId: originId)],
    ];
    // Boarding a given line at a given station is worth doing once: arriving
    // there again with more changes behind us can never be better.
    final seen = <String>{
      for (final lineId in _linesThrough(originId, allowLowFrequency))
        '$originId@$lineId',
    };

    // The rider's FIRST move can be a walk rather than a ride. Standing at
    // Dadar Western bound for Kalyan, nobody rides a Western train anywhere:
    // they cross the bridge to Dadar Central and board there.
    //
    // `_rideOut` never lets a leg end where it began, so without this the
    // origin's own bridge is not in the search space at all, and the planner
    // has to ride at least one station before any walk is offered. From Dadar
    // Western that made one stop to Prabhadevi and the Parel bridge the
    // cheapest legal route: the same number of changes, one station longer,
    // and not what any rider does. Found 25 Aug 2026.
    var firstRound = true;

    while (frontier.isNotEmpty) {
      // Everywhere reachable without getting off the train.
      final reached = <List<_Leg>>[];
      for (final route in frontier) {
        reached.addAll(_rideOut(route, seen, allowLowFrequency));
      }

      // Done if any of them is the destination. Take the shortest, since they all
      // cost the same number of changes.
      final arrivals = reached
          .where((r) => r.last.toId == destinationId)
          .toList();
      if (arrivals.isNotEmpty) {
        arrivals.sort(
          (a, b) => _stationsTravelled(a).compareTo(_stationsTravelled(b)),
        );
        return arrivals.first;
      }

      // Shortest routes claim change points first. Without this, which of two
      // equally-convenient boardings survives the `seen` filter is iteration
      // order, and the 12 Jul field data showed the loser: a chain that rode
      // past Kopar to Diva and doubled back through Kopar on the Vasai line.
      reached.sort(
        (a, b) => _stationsTravelled(a).compareTo(_stationsTravelled(b)),
      );

      // Not reachable on this many changes, so change trains once more, wherever
      // a change is possible, and search again. A change point is the station
      // the leg ends at, and also its walk partner across the foot overbridge
      // when it has one (get off at Dadar, walk to Dadar Western).
      final next = <List<_Leg>>[];
      // On the first pass the un-ridden origin legs are change candidates too,
      // which is what puts "walk across before boarding anything" on the table.
      for (final route in [if (firstRound) ...frontier, ...reached]) {
        final leg = route.last;
        var walkTo = _walkPartner[leg.toId];
        // An endpoint-only bridge is available only when the rider is actually
        // at one of its ends, which means one of its two stations has to be
        // this journey's own origin or destination. Mid-journey it is not a
        // route anybody takes.
        if (walkTo != null &&
            _endpointOnlyWalkKeys.contains(_pairKey(leg.toId, walkTo)) &&
            leg.toId != originId &&
            leg.toId != destinationId &&
            walkTo != originId &&
            walkTo != destinationId) {
          walkTo = null;
        }
        for (final boardAt in [leg.toId, ?walkTo]) {
          for (final lineId in _linesThrough(boardAt, allowLowFrequency)) {
            // Staying on a through service is not a change; but a through
            // relationship cannot survive a walk to a different station.
            if (boardAt == leg.toId && _runsThrough(lineId, leg.lineId)) {
              continue;
            }
            if (!seen.add('$boardAt@$lineId')) continue;
            next.add([
              ...route,
              _Leg(lineId: lineId, fromId: boardAt, toId: boardAt),
            ]);
          }
        }
      }
      frontier = next;
      firstRound = false;
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
  List<List<_Leg>> _rideOut(
    List<_Leg> route,
    Set<String> seen,
    bool allowLowFrequency,
  ) {
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
        for (final lineId in _linesThrough(stopId, allowLowFrequency)) {
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
    String requestedDestinationId,
  ) {
    // Flatten the legs into one chain. A leg normally starts at the station the
    // previous one ended on, so drop the shared station; after a walk
    // interchange it starts at the partner station instead, and BOTH stations
    // belong on the chain (the rider passes through each on foot).
    final chainIds = <String>[];
    for (final leg in legs) {
      final ids = _segmentIds(leg.lineId, leg.fromId, leg.toId);
      if (chainIds.isEmpty || chainIds.last != ids.first) {
        chainIds.addAll(ids);
      } else {
        chainIds.addAll(ids.skip(1));
      }
    }

    // An interchange is where one leg hands over to the next AND that means
    // getting off a train. Crossing a declared through junction (Kasara onto
    // the trunk at Kalyan) is a leg boundary but not a change: the train runs
    // through and the rider stays put. Announcing "get off at Kalyan" there would
    // put them on a platform for no reason.
    final interchanges = <Interchange>[];
    for (var i = 1; i < legs.length; i++) {
      // A walk interchange starts the new leg at a DIFFERENT station than the
      // old leg ended on; the rider alights at the old one and crosses the foot
      // overbridge. A same-station leg boundary on a through service is no
      // change at all.
      final walked = legs[i].fromId != legs[i - 1].toId;
      if (!walked && _runsThrough(legs[i].lineId, legs[i - 1].lineId)) {
        continue;
      }
      final onto = linesById[legs[i].lineId]!;
      final from = linesById[legs[i - 1].lineId]!;
      // Qualify a same-named walk target with the line being boarded.
      //
      // NOT LIVE AGAINST TODAY'S DATA, and the comment here used to say the
      // opposite. Both halves of the Dadar complex WERE named plain "Dadar",
      // which is what this branch was written for; `554063f` renamed them to
      // Dadar Central and Dadar Western on 25 Aug 2026, and Parel/Prabhadevi
      // never shared a name, so no walk pair takes this path now.
      //
      // KEPT ANYWAY, because the names are not ours to promise: the station
      // JSON is GENERATED by tool/build_stations.py out of OSM, and a
      // regenerated pair that shares a name again would otherwise announce
      // "walk across to Dadar" while standing at Dadar. The names are pinned
      // by journey_planner_test's "THE TWO HALVES NO LONGER SHARE A NAME".
      //
      // The qualifier is the LINE's short name, which exists in English only,
      // so a Hindi or Marathi ride says "दादर Western". That is the same
      // English-line-name compromise SpokenCopy documents, and it is how a
      // Mumbai rider says it anyway.
      SpokenName? walkTo;
      if (walked) {
        final alight = stationsById[legs[i - 1].toId]!;
        final board = stationsById[legs[i].fromId]!;
        walkTo = board.name == alight.name
            ? SpokenName(
                en: '${board.name} ${onto.shortName}',
                hi: '${board.nameHi} ${onto.shortName}',
                mr: '${board.nameMr} ${onto.shortName}',
              )
            : board.spokenName;
      }
      interchanges.add(
        Interchange(
          stationId: legs[i - 1].toId,
          fromLineId: from.id,
          toLineId: onto.id,
          toLineShortName: onto.shortName,
          towardsStationName:
              stationsById[_directionTerminalId(legs[i])]!.spokenName,
          isSameNamedService: !walked && onto.shortName == from.shortName,
          walkToStationName: walkTo,
          platform: onto.platforms[legs[i].fromId],
        ),
      );
    }

    return Journey(
      chain: [for (final id in chainIds) stationsById[id]!],
      originStationId: originId,
      destinationStationId: destinationId,
      requestedDestinationId: requestedDestinationId,
      // Resolved HERE because the walk-on station is off the chain, so the
      // Journey itself cannot look it up. Null on the ordinary ride, and the
      // null is what every surface downstream tests.
      walkOnStationName: requestedDestinationId == destinationId
          ? null
          : stationsById[requestedDestinationId]?.spokenName,
      overshootStations: [
        for (final id in _overshootPins(
          legs.last,
          destinationId,
          chainIds.toSet(),
        ))
          stationsById[id]!,
      ],
      wrongWayStations: [
        for (final id in _wrongWayPins(legs.first, originId, chainIds.toSet()))
          stationsById[id]!,
      ],
      interchanges: interchanges,
    );
  }

  /// The safety-net pins one station past the destination.
  ///
  /// Ordinarily the next station along the final leg's own line. At the END of
  /// that line the train does not stop existing: through services run it onto a
  /// branch, so every branch declared as through-running from here gets its own
  /// pin. Which one the train actually takes is unknowable from the plan (a
  /// Kalyan train continues to Kasara or to Karjat, or terminates), so the net
  /// covers all of them rather than guessing one.
  ///
  /// Only DECLARED through services count, never same-name inference: that was
  /// the v1 rule the 12 Jul audit killed.
  List<String> _overshootPins(
    _Leg finalLeg,
    String destinationId,
    Set<String> alreadyInChain,
  ) {
    final onOwnLine = _stationPast(finalLeg, destinationId);
    if (onOwnLine != null) return [onOwnLine];

    final pins = <String>[];
    for (final pair in throughServices) {
      if (!pair.contains(finalLeg.lineId)) continue;
      final ontoId = pair.first == finalLeg.lineId ? pair.last : pair.first;
      final ids = linesById[ontoId]?.stationIds;
      if (ids == null) continue;
      final at = ids.indexOf(destinationId);
      // The destination has to be an END of the onward line for the train to
      // run through it; the pin is that line's next station inward.
      final String? pin;
      if (at == 0) {
        pin = ids.length > 1 ? ids[1] : null;
      } else if (at == ids.length - 1) {
        pin = ids.length > 1 ? ids[ids.length - 2] : null;
      } else {
        pin = null;
      }
      // A pin the ride already passed would send the rider backwards.
      if (pin != null && !alreadyInChain.contains(pin) && !pins.contains(pin)) {
        pins.add(pin);
      }
    }
    return pins;
  }

  /// The pins one station BEHIND the origin, for WRONG_DIRECTION.
  ///
  /// Mirrors [_overshootPins] exactly, stepping the other way: ordinarily the
  /// previous station on the first leg's own line, and at a TERMINUS origin one
  /// per branch that runs back out of it. A rider at Kalyan bound for Dadar who
  /// takes the wrong platform is on a Kasara train or a Karjat train, and the
  /// plan cannot know which, so both are pinned.
  ///
  /// Returns nothing when the origin has no station behind it (CSMT, Churchgate:
  /// every train leaves the same way, so there is no wrong direction to catch),
  /// and nothing when the station behind is one the ride passes anyway, which
  /// would pin a station the rider is meant to reach.
  List<String> _wrongWayPins(
    _Leg firstLeg,
    String originId,
    Set<String> alreadyInChain,
  ) {
    final onOwnLine = _stationBehind(firstLeg, originId);
    if (onOwnLine != null) {
      return alreadyInChain.contains(onOwnLine) ? const [] : [onOwnLine];
    }

    final pins = <String>[];
    for (final pair in throughServices) {
      if (!pair.contains(firstLeg.lineId)) continue;
      final ontoId = pair.first == firstLeg.lineId ? pair.last : pair.first;
      final ids = linesById[ontoId]?.stationIds;
      if (ids == null) continue;
      final at = ids.indexOf(originId);
      // The origin has to be an END of the branch for a train to run back out
      // along it; the pin is that branch's next station outward.
      final String? pin;
      if (at == 0) {
        pin = ids.length > 1 ? ids[1] : null;
      } else if (at == ids.length - 1) {
        pin = ids.length > 1 ? ids[ids.length - 2] : null;
      } else {
        pin = null;
      }
      if (pin != null && !alreadyInChain.contains(pin) && !pins.contains(pin)) {
        pins.add(pin);
      }
    }
    return pins;
  }

  /// The station before [originId] on the first leg's line, against the
  /// direction of travel. Null at the end of the line, and null for a
  /// degenerate single-station leg, which has no direction to be against.
  String? _stationBehind(_Leg firstLeg, String originId) {
    final ids = linesById[firstLeg.lineId]!.stationIds;
    final from = ids.indexOf(firstLeg.fromId);
    final to = ids.indexOf(firstLeg.toId);
    if (from == to) return null;
    final step = to > from ? 1 : -1;
    final behind = ids.indexOf(originId) - step;
    return behind >= 0 && behind < ids.length ? ids[behind] : null;
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
    (total, leg) =>
        total + _segmentIds(leg.lineId, leg.fromId, leg.toId).length,
  );

  Iterable<String> _linesThrough(String stationId, bool allowLowFrequency) =>
      linesById.values
          .where(
            (line) =>
                (allowLowFrequency || !line.lowFrequency) &&
                line.stationIds.contains(stationId),
          )
          .map((line) => line.id);
}

/// A continuous ride on one line, from boarding it to leaving it.
class _Leg {
  const _Leg({required this.lineId, required this.fromId, required this.toId});

  final String lineId;
  final String fromId;
  final String toId;

  _Leg copyWith({String? toId}) =>
      _Leg(lineId: lineId, fromId: fromId, toId: toId ?? this.toId);
}
