import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/models/line.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/journey_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Planned against the REAL bundled network, not fixtures. The planner's whole job
/// is to replace hand-authored ride chains with routes derived from the real lines,
/// so testing it against a toy graph would test the wrong thing.
JourneyPlanner _planner() {
  final raw = File('assets/stations/mumbai_suburban.json').readAsStringSync();
  final doc = jsonDecode(raw) as Map<String, dynamic>;
  final stations = (doc['stations'] as List)
      .cast<Map<String, dynamic>>()
      .map(Station.fromJson);
  final lines =
      (doc['lines'] as List).cast<Map<String, dynamic>>().map(Line.fromJson);
  return JourneyPlanner(
    stationsById: {for (final s in stations) s.id: s},
    linesById: {for (final l in lines) l.id: l},
  );
}

List<String> _ids(Iterable<Station> stations) =>
    stations.map((s) => s.id).toList();

void main() {
  test('Kalyan to Thane is one line, no change, with Mulund as the overshoot', () {
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'thane');

    // The exact 8 stations of the 12 Jul field ride, plus the overshoot pin.
    expect(_ids(journey.chain), [
      'kalyan', 'thakurli', 'dombivli', 'kopar', 'diva',
      'mumbra', 'kalwa', 'thane', 'mulund',
    ]);
    expect(journey.destinationStationId, 'thane');
    expect(journey.overshootStationId, 'mulund');
    expect(journey.interchanges, isEmpty);
  });

  test('Kalyan to Digha reproduces the hand-authored field-ride chain', () {
    // This is the guarantee that let the `harbour_ride_kalyan_digha` fake line be
    // deleted: the planner derives that exact chain from the real Central and
    // Trans-Harbour lines, including the Airoli overshoot pin.
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'digha');

    expect(_ids(journey.chain), [
      'kalyan', 'thakurli', 'dombivli', 'kopar', 'diva',
      'mumbra', 'kalwa', 'thane', 'digha', 'airoli',
    ]);
    expect(journey.destinationStationId, 'digha');
    expect(journey.overshootStationId, 'airoli');

    expect(journey.interchanges, hasLength(1));
    final change = journey.interchanges.single;
    expect(change.stationId, 'thane');
    expect(change.fromLineId, 'central_csmt_kalyan');
    expect(change.toLineShortName, 'Trans Harbour');
    expect(change.platform, '9, 10, or 10 A');
  });

  test('the interchange announcement keeps the platform instruction', () {
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'digha');

    expect(
      journey.arrivalAnnouncements['thane'],
      'You have reached Thane. Change here to the Trans Harbour line. '
      'Get off the train, go to platform number 9, 10, or 10 A, then board the '
      'Trans Harbour train to continue to your destination.',
    );
    expect(
      journey.arrivalAnnouncements['digha'],
      'You have arrived at your destination, Digha Gaon.',
    );

    // The destination and the interchange are the two points the rider must act
    // on, so both get an outer approach fence; ordinary stations do not.
    expect(journey.approachRadiusM.keys, containsAll(['thane', 'digha']));
    expect(journey.approachRadiusM.containsKey('kalwa'), isFalse);
  });

  test('a destination at the end of a line has no overshoot pin', () {
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'kasara');

    expect(journey.chain.last.id, 'kasara');
    expect(journey.overshootStationId, isNull);
  });

  test('riding a branch through its junction is not a change of train', () {
    // Shahad sits on the Kasara branch, Dombivli on the trunk, so the two are
    // separate lines in the data and crossing Kalyan looks like an interchange.
    // It is not: a Kasara train runs THROUGH Kalyan and on down the trunk, and the
    // rider sits still. The debug build announced "Change at Kalyan onto Central"
    // to a rider already on Central, which would have put them on a platform for
    // no reason.
    final journey = _planner().plan(originId: 'shahad', destinationId: 'dombivli');

    expect(_ids(journey.chain), [
      'shahad', 'kalyan', 'thakurli', 'dombivli', 'kopar',
    ]);
    expect(journey.interchanges, isEmpty);
    expect(journey.overshootStationId, 'kopar');

    // And so the only thing said at Kalyan is the ordinary passing ping.
    expect(journey.arrivalAnnouncements.containsKey('kalyan'), isFalse);
    expect(journey.approachRadiusM.containsKey('kalyan'), isFalse);
  });

  test('a change between two real services is still a change', () {
    // The guard above must not swallow genuine interchanges: Central to
    // Trans-Harbour at Thane is two different railways and a real walk.
    final journey = _planner().plan(originId: 'shahad', destinationId: 'digha');

    expect(journey.interchanges, hasLength(1));
    expect(journey.interchanges.single.stationId, 'thane');
    expect(journey.interchanges.single.toLineShortName, 'Trans Harbour');
  });

  test('the route with the fewest changes wins', () {
    // Kalyan -> Vashi is reachable via Thane (one change, Central to
    // Trans-Harbour) or via Kurla (Central to Harbour). Either is one change;
    // what must NOT happen is a three-line detour.
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'vashi');

    expect(journey.interchanges, hasLength(1));
    expect(journey.chain.first.id, 'kalyan');
    expect(_ids(journey.chain), contains('vashi'));
  });

  test('a journey along one line never invents a change', () {
    final journey =
        _planner().plan(originId: 'churchgate', destinationId: 'borivali');

    expect(journey.interchanges, isEmpty);
    expect(journey.chain.first.id, 'churchgate');
    expect(_ids(journey.chain), contains('borivali'));
  });

  test('every station on the chain is adjacent to the next, no gaps', () {
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'digha');

    // A chain with a hole in it would silently skip a station's announcement.
    for (var i = 0; i < journey.chain.length - 1; i++) {
      expect(
        journey.chain[i].id,
        isNot(journey.chain[i + 1].id),
        reason: 'chain repeats a station at index $i',
      );
    }
    expect(
      _ids(journey.chain).toSet(),
      hasLength(journey.chain.length),
      reason: 'chain visits the same station twice',
    );
  });

  test('an unknown station is rejected', () {
    expect(
      () => _planner().plan(originId: 'kalyan', destinationId: 'hogwarts'),
      throwsArgumentError,
    );
  });

  test('travelling to where you already are is rejected', () {
    expect(
      () => _planner().plan(originId: 'kalyan', destinationId: 'kalyan'),
      throwsArgumentError,
    );
  });
}
