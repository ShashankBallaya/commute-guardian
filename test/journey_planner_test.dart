import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
    throughServices: [
      for (final pair in doc['throughServices'] as List)
        (pair as List).cast<String>(),
    ],
    walkInterchanges: [
      for (final pair in doc['walkInterchanges'] as List)
        (pair as List).cast<String>(),
    ],
  );
}

List<String> _ids(Iterable<Station> stations) =>
    stations.map((s) => s.id).toList();

void main() {
  test('Kalyan to Thane is one line, no change, with Mulund as the overshoot', () {
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'thane');

    // The exact 8 stations of the 12 Jul field ride. The overshoot pin is no
    // longer a chain member: the chain ends at the destination and pins are
    // carried separately.
    expect(_ids(journey.chain), [
      'kalyan', 'thakurli', 'dombivli', 'kopar', 'diva',
      'mumbra', 'kalwa', 'thane',
    ]);
    expect(journey.destinationStationId, 'thane');
    expect(journey.overshootStationIds, ['mulund']);
    expect(journey.interchanges, isEmpty);
  });

  test('Kalyan to Digha reproduces the hand-authored field-ride chain', () {
    // This is the guarantee that let the `harbour_ride_kalyan_digha` fake line be
    // deleted: the planner derives that exact chain from the real Central and
    // Trans-Harbour lines, including the Airoli overshoot pin.
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'digha');

    expect(_ids(journey.chain), [
      'kalyan', 'thakurli', 'dombivli', 'kopar', 'diva',
      'mumbra', 'kalwa', 'thane', 'digha',
    ]);
    expect(journey.destinationStationId, 'digha');
    expect(journey.overshootStationIds, ['airoli']);

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
    expect(journey.overshootStationIds, isEmpty);
  });

  test('a terminus destination is netted on EVERY branch a train can run on '
      'to (Thane to Kalyan, the 13 Jul known gap)', () {
    // The trunk ends at Kalyan, but real trains run THROUGH it onto both the
    // Kasara and the Karjat branch, and which one is genuinely ambiguous from
    // the plan alone. A rider who sleeps through Kalyan therefore wakes in
    // Shahad or in Vithalwadi, and until now got no warning in either case
    // because the trunk had nothing past Kalyan to pin.
    //
    // Both pins are declared by throughServices, not guessed.
    final journey = _planner().plan(originId: 'thane', destinationId: 'kalyan');

    expect(journey.destinationStationId, 'kalyan');
    expect(journey.overshootStationIds, ['shahad', 'vithalwadi']);

    // The chain must stay LINEAR and end at the destination. The two pins
    // diverge geographically, and feeding a fork to the backstop's chain
    // projection is what produced the false "You have passed Thane" on
    // 18 Jul. Pins are proximity-tested, never projected.
    expect(journey.chain.last.id, 'kalyan');
    expect(_ids(journey.chain), isNot(contains('shahad')));
    expect(_ids(journey.chain), isNot(contains('vithalwadi')));
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
      'shahad', 'kalyan', 'thakurli', 'dombivli',
    ]);
    expect(journey.interchanges, isEmpty);
    expect(journey.overshootStationIds, ['kopar']);

    // And so the only thing said at Kalyan is the ordinary passing ping.
    expect(journey.arrivalAnnouncements.containsKey('kalyan'), isFalse);
    expect(journey.approachRadiusM.containsKey('kalyan'), isFalse);
  });

  test('branch to branch across Kalyan IS a change, announced by direction', () {
    // Kasara trains run through Kalyan onto the trunk (owner-confirmed), but no
    // train runs Kasara branch to Karjat branch. Inferring service identity
    // from the shared "Central" short name silently merged all three, planned
    // Shahad -> Ulhasnagar as "no change of train", and would have let the
    // rider sleep through a change they had to make. Hence explicit
    // throughServices pairs in the data instead.
    final journey =
        _planner().plan(originId: 'shahad', destinationId: 'ulhasnagar');

    expect(journey.interchanges, hasLength(1));
    final change = journey.interchanges.single;
    expect(change.stationId, 'kalyan');
    expect(change.isSameNamedService, isTrue);
    expect(change.towardsStationName, 'Karjat');

    // "Change here to the Central line" while sitting on a Central train says
    // nothing. Same-named changes are described by direction instead.
    expect(
      journey.arrivalAnnouncements['kalyan'],
      'You have reached Kalyan. Change trains here. Get off the train, '
      'board the train towards Karjat to continue to your destination.',
    );
  });

  test('the through service works in both directions', () {
    // Up the trunk and onto the Kasara branch: still one train, still silent
    // at Kalyan.
    final journey =
        _planner().plan(originId: 'dombivli', destinationId: 'shahad');

    expect(journey.interchanges, isEmpty);
    expect(_ids(journey.chain), [
      'dombivli', 'thakurli', 'kalyan', 'shahad',
    ]);
    expect(journey.overshootStationIds, ['ambivli']);
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

  test('Central to Western goes over the Dadar foot overbridge, not the MEMU', () {
    // The 13 Jul field report: Shahad -> Borivali planned via the hourly
    // Diva-Vasai MEMU, because Dadar Central and Dadar Western were two
    // unconnected stations and the human route did not exist in the graph.
    final journey =
        _planner().plan(originId: 'shahad', destinationId: 'borivali');

    final ids = _ids(journey.chain);
    expect(ids, isNot(contains('vasai_road')));
    expect(ids.indexOf('dadar_western'), ids.indexOf('dadar') + 1,
        reason: 'the walk crosses from Dadar Central straight to Dadar Western');

    expect(journey.interchanges, hasLength(1));
    final change = journey.interchanges.single;
    expect(change.stationId, 'dadar');
    expect(change.walkToStationName, 'Dadar Western');
    expect(
      journey.arrivalAnnouncements['dadar'],
      'You have reached Dadar. Get off the train and walk across to '
      'Dadar Western, then board the Western train towards Dahanu Road to '
      'continue to your destination.',
    );
  });

  test('low-frequency MEMU lines are a last resort, not a shortcut', () {
    // Vasai Road is on the Western line, so it is reachable without the MEMU:
    // the planner must go over Dadar even though the MEMU would save a change.
    final viaWestern =
        _planner().plan(originId: 'dombivli', destinationId: 'vasai_road');
    expect(_ids(viaWestern.chain), isNot(contains('kharbao')));
    expect(_ids(viaWestern.chain), contains('dadar_western'));

    // Kharbao is ONLY on the MEMU line, so the fallback must still route there,
    // and via the nearest boarding point (Kopar), not past it and back.
    final forced =
        _planner().plan(originId: 'dombivli', destinationId: 'kharbao');
    final ids = _ids(forced.chain);
    expect(ids, contains('kharbao'));
    expect(forced.interchanges.single.stationId, 'kopar');
    expect(ids.toSet(), hasLength(ids.length),
        reason: 'a chain that doubles back visits a station twice');
  });

  test('any plannable pair yields a sane chain (sampled sweep)', () {
    // The individual cases above are the ones we know about. This guards the
    // ones we do not: every chain must start at the origin, contain the
    // destination, visit no station twice, and keep each interchange on the
    // chain. Seeded so a failure reproduces.
    final planner = _planner();
    final ids = planner.stationsById.keys.toList()..sort();
    final rng = math.Random(42);

    for (var n = 0; n < 150; n++) {
      final originId = ids[rng.nextInt(ids.length)];
      final destinationId = ids[rng.nextInt(ids.length)];
      if (originId == destinationId) continue;

      final journey =
          planner.plan(originId: originId, destinationId: destinationId);
      final chainIds = _ids(journey.chain);
      final label = '$originId -> $destinationId';

      expect(chainIds.first, originId, reason: label);
      expect(chainIds, contains(destinationId), reason: label);
      expect(chainIds.toSet(), hasLength(chainIds.length),
          reason: '$label visits a station twice: $chainIds');
      for (final interchange in journey.interchanges) {
        expect(chainIds, contains(interchange.stationId), reason: label);
      }
    }
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
