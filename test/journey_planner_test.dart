import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:commute_guardian/models/line.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/announcement_templates.dart';
import 'package:commute_guardian/services/journey_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Planned against the REAL bundled network, not fixtures. The planner's whole job
/// is to replace hand-authored ride chains with routes derived from the real lines,
/// so testing it against a toy graph would test the wrong thing.
JourneyPlanner _planner() {
  final raw = File('assets/stations/mumbai_suburban.json').readAsStringSync();
  final doc = jsonDecode(raw) as Map<String, dynamic>;
  final stations = (doc['stations'] as List).cast<Map<String, dynamic>>().map(
    Station.fromJson,
  );
  final lines = (doc['lines'] as List).cast<Map<String, dynamic>>().map(
    Line.fromJson,
  );
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
    endpointOnlyWalkInterchanges: [
      for (final pair
          in doc['endpointOnlyWalkInterchanges'] as List? ?? const [])
        (pair as List).cast<String>(),
    ],
  );
}

List<String> _ids(Iterable<Station> stations) =>
    stations.map((s) => s.id).toList();

/// The station across the foot overbridge, straight out of the bundled data so
/// the tests never carry their own copy of a pairing the generator owns.
String? _walkPartnerOf(String id) {
  final doc =
      jsonDecode(
            File('assets/stations/mumbai_suburban.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final pair in (doc['walkInterchanges'] as List).cast<List<dynamic>>()) {
    if (pair[0] == id) return pair[1] as String;
    if (pair[1] == id) return pair[0] as String;
  }
  return null;
}

void main() {
  test(
    'Kalyan to Thane is one line, no change, with Mulund as the overshoot',
    () {
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'thane',
      );

      // The exact 8 stations of the 12 Jul field ride. The overshoot pin is no
      // longer a chain member: the chain ends at the destination and pins are
      // carried separately.
      expect(_ids(journey.chain), [
        'kalyan',
        'thakurli',
        'dombivli',
        'kopar',
        'diva',
        'mumbra',
        'kalwa',
        'thane',
      ]);
      expect(journey.destinationStationId, 'thane');
      expect(journey.overshootStationIds, ['mulund']);
      expect(journey.interchanges, isEmpty);
    },
  );

  test('Kalyan to Digha reproduces the hand-authored field-ride chain', () {
    // This is the guarantee that let the `harbour_ride_kalyan_digha` fake line be
    // deleted: the planner derives that exact chain from the real Central and
    // Trans-Harbour lines, including the Airoli overshoot pin.
    final journey = _planner().plan(originId: 'kalyan', destinationId: 'digha');

    expect(_ids(journey.chain), [
      'kalyan',
      'thakurli',
      'dombivli',
      'kopar',
      'diva',
      'mumbra',
      'kalwa',
      'thane',
      'digha',
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
      journey.arrivalAnnouncementsIn()['thane'],
      'You have reached Thane. Change here to the Trans Harbour line. '
      'Get off the train, go to platform number 9, 10, or 10 A, then board the '
      'Trans Harbour train to continue to your destination.',
    );
    expect(
      journey.arrivalAnnouncementsIn()['digha'],
      'You have arrived at your destination, Digha Gaon.',
    );

    // The destination and the interchange are the two points the rider must act
    // on, so both get an outer approach fence; ordinary stations do not.
    expect(journey.approachRadiusM.keys, containsAll(['thane', 'digha']));
    expect(journey.approachRadiusM.containsKey('kalwa'), isFalse);
  });

  test('a destination at the end of a line has no overshoot pin', () {
    final journey = _planner().plan(
      originId: 'kalyan',
      destinationId: 'kasara',
    );

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
    final journey = _planner().plan(
      originId: 'shahad',
      destinationId: 'dombivli',
    );

    expect(_ids(journey.chain), ['shahad', 'kalyan', 'thakurli', 'dombivli']);
    expect(journey.interchanges, isEmpty);
    expect(journey.overshootStationIds, ['kopar']);

    // And so the only thing said at Kalyan is the ordinary passing ping.
    expect(journey.arrivalAnnouncementsIn().containsKey('kalyan'), isFalse);
    expect(journey.approachRadiusM.containsKey('kalyan'), isFalse);
  });

  test('branch to branch across Kalyan IS a change, announced by direction', () {
    // Kasara trains run through Kalyan onto the trunk (owner-confirmed), but no
    // train runs Kasara branch to Karjat branch. Inferring service identity
    // from the shared "Central" short name silently merged all three, planned
    // Shahad -> Ulhasnagar as "no change of train", and would have let the
    // rider sleep through a change they had to make. Hence explicit
    // throughServices pairs in the data instead.
    final journey = _planner().plan(
      originId: 'shahad',
      destinationId: 'ulhasnagar',
    );

    expect(journey.interchanges, hasLength(1));
    final change = journey.interchanges.single;
    expect(change.stationId, 'kalyan');
    expect(change.isSameNamedService, isTrue);
    expect(change.towardsStationName.en, 'Karjat');

    // "Change here to the Central line" while sitting on a Central train says
    // nothing. Same-named changes are described by direction instead.
    expect(
      journey.arrivalAnnouncementsIn()['kalyan'],
      'You have reached Kalyan. Change trains here. Get off the train, '
      'board the train towards Karjat to continue to your destination.',
    );
  });

  test('the through service works in both directions', () {
    // Up the trunk and onto the Kasara branch: still one train, still silent
    // at Kalyan.
    final journey = _planner().plan(
      originId: 'dombivli',
      destinationId: 'shahad',
    );

    expect(journey.interchanges, isEmpty);
    expect(_ids(journey.chain), ['dombivli', 'thakurli', 'kalyan', 'shahad']);
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
    final journey = _planner().plan(
      originId: 'churchgate',
      destinationId: 'borivali',
    );

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

  test(
    'Central to Western goes over the Dadar foot overbridge, not the MEMU',
    () {
      // The 13 Jul field report: Shahad -> Borivali planned via the hourly
      // Diva-Vasai MEMU, because Dadar Central and Dadar Western were two
      // unconnected stations and the human route did not exist in the graph.
      final journey = _planner().plan(
        originId: 'shahad',
        destinationId: 'borivali',
      );

      final ids = _ids(journey.chain);
      expect(ids, isNot(contains('vasai_road')));
      expect(
        ids.indexOf('dadar_western'),
        ids.indexOf('dadar') + 1,
        reason: 'the walk crosses from Dadar Central straight to Dadar Western',
      );

      expect(journey.interchanges, hasLength(1));
      final change = journey.interchanges.single;
      expect(change.stationId, 'dadar');
      expect(change.walkToStationName?.en, 'Dadar Western');
      // NO LINE QUALIFIER ANY MORE. The two halves used to share the name
      // "Dadar", so "walk across to Dadar" said nothing and the copy borrowed
      // the English line name to tell them apart. Since 25 Aug 2026 the data
      // names them Dadar Central and Dadar Western, so the station speaks for
      // itself, in every language.
      expect(change.walkToStationName?.hi, 'दादर वेस्टर्न');
      // THE PLATFORM IS IN THE SENTENCE SINCE 29 Aug 2026, and it is keyed by
      // direction: this journey is heading north, so it is the Borivali-side
      // pair, 1 or 3. A Churchgate-bound rider off the same platform gets 2 or
      // 4. Both numbers are offered because the app does not know whether the
      // rider boards a fast or a slow train and by the 12 Jul decision never
      // will.
      expect(
        journey.arrivalAnnouncementsIn()['dadar'],
        'You have reached Dadar Central. Get off the train and walk across to '
        'Dadar Western, then go to platform number 1 or 3, then board the '
        'Western train towards Dahanu Road to continue to your destination.',
      );
      // The far half is a confirmation the rider hears once they are across.
      expect(
        journey.arrivalAnnouncementsIn()['dadar_western'],
        'You are at Dadar Western. Take the Western train towards Dahanu Road.',
      );
    },
  );

  test('low-frequency MEMU lines are a last resort, not a shortcut', () {
    // Vasai Road is on the Western line, so it is reachable without the MEMU:
    // the planner must go over Dadar even though the MEMU would save a change.
    final viaWestern = _planner().plan(
      originId: 'dombivli',
      destinationId: 'vasai_road',
    );
    expect(_ids(viaWestern.chain), isNot(contains('kharbao')));
    expect(_ids(viaWestern.chain), contains('dadar_western'));

    // Kharbao is ONLY on the MEMU line, so the fallback must still route there,
    // and via the nearest boarding point (Kopar), not past it and back.
    final forced = _planner().plan(
      originId: 'dombivli',
      destinationId: 'kharbao',
    );
    final ids = _ids(forced.chain);
    expect(ids, contains('kharbao'));
    expect(forced.interchanges.single.stationId, 'kopar');
    expect(
      ids.toSet(),
      hasLength(ids.length),
      reason: 'a chain that doubles back visits a station twice',
    );
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

      // Two sides of one foot overbridge is a walk, not a journey, and the
      // planner refuses it by design. See the Dadar tests below.
      if (_walkPartnerOf(destinationId) == originId) continue;

      final journey = planner.plan(
        originId: originId,
        destinationId: destinationId,
      );
      final chainIds = _ids(journey.chain);
      final label = '$originId -> $destinationId';

      expect(chainIds.first, originId, reason: label);
      // THE RIDE MAY END AT THE OTHER HALF OF A WALK INTERCHANGE, on purpose.
      // Dadar Central and Dadar Western are one station to a rider, so the
      // planner picks the side that suits the route rather than obeying the
      // half the rider happened to tap. Everywhere else this is an exact match.
      expect(
        chainIds,
        anyOf(
          contains(destinationId),
          contains(_walkPartnerOf(destinationId) ?? '__none__'),
        ),
        reason: label,
      );
      expect(
        chainIds.toSet(),
        hasLength(chainIds.length),
        reason: '$label visits a station twice: $chainIds',
      );
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

  group('wrong-way pins', () {
    test('mid-line, the pin is the station behind the origin', () {
      // Dadar toward Kalyan: the wrong platform sends the rider back to Parel.
      final journey = _planner().plan(
        originId: 'dadar',
        destinationId: 'kalyan',
      );
      expect(_ids(journey.wrongWayStations), ['parel']);

      // Riding the other way out of the same station it is the station on the
      // other side, which is what makes this a DIRECTION test. Straight-line
      // distance from the destination could not tell these two apart.
      final back = _planner().plan(originId: 'dadar', destinationId: 'csmt');
      expect(_ids(back.wrongWayStations), ['matunga']);
    });

    test('A TERMINUS ORIGIN PINS EVERY BRANCH BEHIND IT', () {
      // Kalyan toward Dadar. A rider on the wrong platform at Kalyan is on a
      // Kasara train or a Karjat train and the plan cannot know which, exactly
      // as the overshoot net cannot know which branch a train runs onto.
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'dadar',
      );
      expect(_ids(journey.wrongWayStations), ['shahad', 'vithalwadi']);
    });

    test('an origin at the end of the network has no wrong direction', () {
      // Every train out of CSMT leaves the same way. A pin here would have to
      // be invented, and this engine only ever speaks from evidence.
      final journey = _planner().plan(
        originId: 'csmt',
        destinationId: 'kalyan',
      );
      expect(journey.wrongWayStations, isEmpty);
    });

    test('no pin is ever a station the ride is meant to reach', () {
      // The one way this feature could do real harm: warning a rider off a
      // train that is taking them exactly where they asked to go. Checked
      // across every pair the survey covers, not argued.
      const pairs = [
        ['kalyan', 'dadar'],
        ['dadar', 'kalyan'],
        ['thane', 'panvel'],
        ['panvel', 'thane'],
        ['borivali', 'churchgate'],
        ['csmt', 'panvel'],
        ['shahad', 'borivali'],
        ['vasai_road', 'diva'],
        ['nerul', 'uran'],
        ['goregaon', 'csmt'],
        ['karjat', 'thane'],
        ['kasara', 'dadar'],
      ];
      for (final pair in pairs) {
        final journey = _planner().plan(
          originId: pair.first,
          destinationId: pair.last,
        );
        final chainIds = _ids(journey.chain).toSet();
        final label = '${pair.first} -> ${pair.last}';
        for (final pin in journey.wrongWayStations) {
          expect(chainIds, isNot(contains(pin.id)), reason: label);
          expect(
            _ids(journey.overshootStations),
            isNot(contains(pin.id)),
            reason: label,
          );
        }
      }
    });
  });

  group('THE DADAR BRIDGE, three bugs reported 25 Aug 2026', () {
    // All three were found by the owner reading routes the app offered him,
    // and all three had the same shape: the planner was right about the graph
    // and wrong about Mumbai.

    test('A JOURNEY THAT STARTS AT A BRIDGE WALKS ACROSS IT FIRST', () {
      // `_rideOut` never lets a leg end where it began, so the origin's own
      // bridge was not in the search space: the planner had to ride at least
      // one station before any walk was offered. From Dadar Western that made
      // one stop to Prabhadevi and the Parel bridge the cheapest legal route.
      final journey = _planner().plan(
        originId: 'dadar_western',
        destinationId: 'kalyan',
      );

      expect(journey.interchanges, hasLength(1));
      final change = journey.interchanges.single;
      expect(change.stationId, 'dadar_western');
      expect(change.walkToStationName?.en, 'Dadar Central');
      expect(_ids(journey.chain).first, 'dadar_western');
      expect(_ids(journey.chain), isNot(contains('prabhadevi')));
      expect(_ids(journey.chain), isNot(contains('parel')));
    });

    test(
      'PAREL IS NOT A THROUGH INTERCHANGE, EVEN WHEN IT IS ONE STOP NEARER',
      () {
        // Parel and Prabhadevi are slow-only halts; Dadar is where the fast
        // locals stop. Coming from the south, Prabhadevi arrives one station
        // before Dadar Western, so ranking equal-change routes by stations
        // travelled picked the Parel bridge and saved one stop on a slow train
        // by changing where no fast train calls.
        for (final originId in ['mumbai_central', 'churchgate', 'grant_road']) {
          final journey = _planner().plan(
            originId: originId,
            destinationId: 'kalyan',
          );
          expect(journey.interchanges, hasLength(1), reason: originId);
          expect(
            journey.interchanges.single.stationId,
            'dadar_western',
            reason: '$originId should change at Dadar, not Parel',
          );
        }
      },
    );

    test('STANDING AT PAREL, THE PAREL BRIDGE IS EXACTLY RIGHT', () {
      // The rule is about through journeys, not about the bridge being bad. A
      // rider already at one end of it uses it, and this is what stops the fix
      // above from deleting a real move.
      final journey = _planner().plan(
        originId: 'parel',
        destinationId: 'borivali',
      );

      expect(journey.interchanges, hasLength(1));
      expect(journey.interchanges.single.stationId, 'parel');
      expect(journey.interchanges.single.walkToStationName?.en, 'Prabhadevi');
    });

    test('THE PLANNER PICKS THE SIDE OF DADAR, NOT THE RIDER', () {
      // "Dadar" is one station in a Mumbai head and two rows in the data. A
      // rider on a Central train who taps the Western one has asked for a stop
      // their train does not call at, and the planner used to answer literally.
      final fromCentral = _planner().plan(
        originId: 'kalyan',
        destinationId: 'dadar_western',
      );
      expect(fromCentral.destinationStationId, 'dadar');
      expect(fromCentral.interchanges, isEmpty);

      final fromWestern = _planner().plan(
        originId: 'borivali',
        destinationId: 'dadar',
      );
      expect(fromWestern.destinationStationId, 'dadar_western');
      expect(fromWestern.interchanges, isEmpty);
    });

    test('THE OTHER SIDE OF THE BRIDGE IS A WALK, NOT A JOURNEY', () {
      final planner = _planner();
      expect(
        () => planner.plan(originId: 'dadar', destinationId: 'dadar_western'),
        throwsArgumentError,
      );
      expect(
        () => planner.plan(originId: 'prabhadevi', destinationId: 'parel'),
        throwsArgumentError,
      );
    });

    test('THE TWO HALVES NO LONGER SHARE A NAME', () {
      final planner = _planner();
      expect(planner.stationsById['dadar']!.name, 'Dadar Central');
      expect(planner.stationsById['dadar_western']!.name, 'Dadar Western');
    });
  });

  group('THE SUBSTITUTION IS NOT SILENT ANY MORE, 27 Aug 2026', () {
    // The planner choosing the side of a bridge is right. Choosing it and
    // never saying so is the bug: a rider who asked for Prabhadevi was ridden
    // to Parel, told "Parel", and left to work the rest out on a platform.

    test('the pick survives the plan that overrode it', () {
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'prabhadevi',
      );
      expect(
        journey.destinationStationId,
        'parel',
        reason: 'the train still puts them on the Central platform',
      );
      expect(journey.requestedDestinationId, 'prabhadevi');
      expect(journey.walkOnStationId, 'prabhadevi');
      expect(journey.walkOnStationName?.en, 'Prabhadevi');
    });

    test('the arrival names the platform AND the station they came for', () {
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'prabhadevi',
      );
      expect(
        journey.arrivalAnnouncementsIn()['parel'],
        'You have arrived at your destination, Parel. '
        'Prabhadevi is just across the foot overbridge.',
      );
    });

    test('the same holds for the Dadar bridge', () {
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'dadar_western',
      );
      expect(journey.destinationStationId, 'dadar');
      expect(journey.walkOnStationId, 'dadar_western');
      expect(
        journey.arrivalAnnouncementsIn()['dadar'],
        'You have arrived at your destination, Dadar Central. '
        'Dadar Western is just across the foot overbridge.',
      );
    });

    test('AN ORDINARY RIDE IS UNTOUCHED, and still clip-backed', () {
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'thane',
      );
      expect(journey.requestedDestinationId, 'thane');
      expect(journey.walkOnStationId, isNull);
      expect(journey.walkOnStationName, isNull);
      // BYTE-IDENTICAL to the template the clip pack was cut from. This is the
      // guard that stops the walk-on sentence leaking onto every other ride
      // and silently demoting 127 stations to the device TTS floor.
      expect(
        journey.arrivalAnnouncementsIn()['thane'],
        ClipKind.destination.render('Thane'),
      );
    });

    test('THE WALK-ON ARRIVAL KNOWINGLY GIVES UP ITS CLIP', () {
      // Not an oversight, and pinned so it cannot become one. The appended
      // sentence breaks ClipLibrary's byte-identical rule, so this one
      // announcement drops to device TTS. A Sarvam voice saying half of what
      // the rider needs is worse than a device voice saying all of it.
      final journey = _planner().plan(
        originId: 'kalyan',
        destinationId: 'prabhadevi',
      );
      expect(
        journey.arrivalAnnouncementsIn()['parel'],
        isNot(ClipKind.destination.render('Parel')),
      );
    });

    test('REPLANNING FROM THE STORED PICK REBUILDS THE SAME RIDE', () {
      // The resume and the iOS relaunch both replan from the persisted id. If
      // the resolved id were stored instead, Parel would replan to Parel, the
      // walk would vanish, and a resumed ride would fall silent exactly where
      // the first one spoke.
      final first = _planner().plan(
        originId: 'kalyan',
        destinationId: 'prabhadevi',
      );
      final resumed = _planner().plan(
        originId: first.originStationId,
        destinationId: first.requestedDestinationId,
      );
      expect(_ids(resumed.chain), _ids(first.chain));
      expect(resumed.destinationStationId, first.destinationStationId);
      expect(resumed.walkOnStationId, 'prabhadevi');
    });
  });

  group('THE PLATFORM DEPENDS ON WHICH WAY YOU ARE GOING, 29 Aug 2026', () {
    // Owner-supplied from the platforms themselves. Thane never needed a
    // direction key because Trans Harbour only leaves Thane one way. Dadar is
    // four different answers at one station, so the old station-only key would
    // have had to pick one and be wrong half the time.
    //
    //   Churchgate direction   2 slow, 4 fast
    //   Borivali direction     1 slow, 3 fast
    //   CSMT direction         9 slow, 12 fast
    //   Kalyan direction       8 slow, 9 A and 10 fast

    String? platformFor(String origin, String destination) => _planner()
        .plan(originId: origin, destinationId: destination)
        .interchanges
        .single
        .platform;

    test('Central to Western, southbound, is the Churchgate pair', () {
      expect(platformFor('kalyan', 'churchgate'), '2 or 4');
    });

    test('Central to Western, northbound, is the Borivali pair', () {
      expect(platformFor('kalyan', 'borivali'), '1 or 3');
    });

    test('Western to Central, northbound, is the Kalyan pair', () {
      // 9 A and 10 are two separate platforms, confirmed twice by the owner,
      // and 9 belongs to the other direction entirely.
      expect(platformFor('borivali', 'kalyan'), '8, 9 A, or 10');
    });

    test('Western to Central, southbound, is the CSMT pair', () {
      expect(platformFor('churchgate', 'byculla'), '9 or 12');
    });

    test('a station with nothing confirmed still announces the change', () {
      // Sparse is the point. Kurla has no curated platform, and the sentence
      // must still tell the rider to change, just without a number.
      final journey = _planner().plan(
        originId: 'churchgate',
        destinationId: 'panvel',
      );
      final change = journey.interchanges.last;
      expect(change.platform, isNull);
      expect(
        journey.arrivalAnnouncementsIn()[change.stationId],
        isNot(contains('platform')),
      );
    });
  });
}
