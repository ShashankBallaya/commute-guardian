import 'dart:io';
import 'dart:math' as math;

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/relaunch_lifeline.dart';
import 'package:commute_guardian/services/ride_resume.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decision the app takes when iOS starts it by itself.
///
/// WHY THIS IS PURE AND WHY IT IS TESTED HERE. The lifeline itself is Swift,
/// which does not compile on the machine this project is written on, so every
/// judgement was deliberately kept on this side: whether the app was woken by
/// movement, whether a ride was interrupted, whether the fix that woke us is
/// still on the rail corridor. All three are reproducible at a desk with no
/// phone, which is the only reason a background relaunch can be tested at all.
///
/// THE RULE, agreed before it was built: auto-resume on relaunch, but ONLY
/// against evidence. Off-corridor gets a notification, not a ride.
void main() {
  late StationRepository repo;

  setUpAll(() {
    repo = StationRepository.parse(
      File(StationRepository.assetPath).readAsStringSync(),
    );
  });

  List<Station> chain(List<String> ids) => [
    for (final id in ids) repo.stationsById[id]!,
  ];

  /// The 16 Aug 2026 ride, every station on it. Density matters: a sparse
  /// chain draws straight lines across geography and calls places near no
  /// railway "on the corridor". See ride_resume_test.dart, where the first
  /// draft of that mistake is written up.
  final homeward = [
    'csmt', 'masjid', 'sandhurst_road', 'byculla', 'chinchpokli',
    'currey_road', 'parel', 'dadar', 'matunga', 'sion', 'kurla',
    'vidyavihar', 'ghatkopar', 'vikhroli', 'kanjurmarg', 'bhandup', 'nahur',
    'mulund', 'thane', 'mumbra', 'diva', 'kopar', 'dombivli', 'thakurli',
    'kalyan', 'shahad',
  ];

  /// The ride the store still believes is in progress. Its fields do not
  /// matter to this decision beyond existing: [interruptedRideFrom] has
  /// already refused a ride that is stale, finished or never had a route.
  final ride = InterruptedRide(
    originId: 'csmt',
    destinationId: 'shahad',
    startedAt: DateTime(2026, 8, 16, 19, 30),
    reachedIndex: 11,
  );

  group('what the platform said', () {
    test('a launch nobody can attribute to movement', () {
      expect(RelaunchAnswer.fromPlatform(null).launchedByLocation, isFalse);
      expect(RelaunchAnswer.fromPlatform(null).hasFix, isFalse);
      expect(RelaunchAnswer.none.launchedByLocation, isFalse);
    });

    test('a full payload from the lifeline', () {
      final answer = RelaunchAnswer.fromPlatform({
        'launchedByLocation': true,
        'lat': 19.2358216,
        'lng': 73.1308101,
        'accuracyM': 65,
        'ageSeconds': 3,
        'authorization': 'always',
        'available': true,
      });

      expect(answer.launchedByLocation, isTrue);
      expect(answer.hasFix, isTrue);
      expect(answer.accuracyM, 65);
      expect(answer.authorization, 'always');
      expect(answer.available, isTrue);
    });

    test('woken with no fix yet, which is a real answer and not an error', () {
      final answer = RelaunchAnswer.fromPlatform({
        'launchedByLocation': true,
        'authorization': 'always',
        'available': true,
      });

      expect(answer.launchedByLocation, isTrue);
      expect(answer.hasFix, isFalse);
      expect(answer.accuracyM, isNull);
    });

    test('NO COORDINATE EVER REACHES THE RIDE LOG', () {
      // The log is exported and mailed from Settings. The Phase 4 privacy note
      // is not negotiable for a diagnostic line either, and this line is the
      // one that would carry a position out of the app if anyone added it.
      final line = RelaunchAnswer.fromPlatform({
        'launchedByLocation': true,
        'lat': 19.2358216,
        'lng': 73.1308101,
        'accuracyM': 65,
        'ageSeconds': 3,
        'authorization': 'always',
        'available': true,
      }).describe();

      expect(line, isNot(contains('19.2')));
      expect(line, isNot(contains('73.1')));
      // What is worth knowing survives.
      expect(line, contains('fix=true'));
      expect(line, contains('65m'));
      expect(line, contains('auth=always'));
    });
  });

  group('THE RELAUNCH DECISION', () {
    /// A fix exactly between Thane and Mumbra: the longest hop on the chain at
    /// 4983 m, so it is 2492 m from the nearest STATION and exactly where a
    /// rider is supposed to be. See ride_resume_test.dart.
    ({double lat, double lng}) onTheTrain() {
      final thane = repo.stationsById['thane']!;
      final mumbra = repo.stationsById['mumbra']!;
      return (
        lat: (thane.lat + mumbra.lat) / 2,
        lng: (thane.lng + mumbra.lng) / 2,
      );
    }

    RelaunchAnswer woken({
      double? lat,
      double? lng,
      double? accuracyM = 65,
      bool byLocation = true,
    }) => RelaunchAnswer(
      launchedByLocation: byLocation,
      lat: lat,
      lng: lng,
      accuracyM: accuracyM,
      available: true,
      authorization: 'always',
    );

    test('AN ORDINARY LAUNCH IS NEVER ACTED ON, however good the evidence', () {
      // The rider is holding the phone. Screen 1's offer asks them, and it
      // asks BECAUSE an app opened an hour later cannot know whether they
      // finished the trip another way.
      final fix = onTheTrain();

      expect(
        relaunchActionFor(
          answer: woken(lat: fix.lat, lng: fix.lng, byLocation: false),
          ride: ride,
          chain: chain(homeward),
        ),
        RelaunchAction.ignore,
      );
    });

    test('woken with no interrupted ride behind it', () {
      final fix = onTheTrain();

      expect(
        relaunchActionFor(
          answer: woken(lat: fix.lat, lng: fix.lng),
          ride: null,
          chain: chain(homeward),
        ),
        RelaunchAction.ignore,
      );
    });

    test('A RIDER STILL ON THE TRAIN GETS THEIR RIDE BACK, unasked', () {
      final fix = onTheTrain();

      expect(
        relaunchActionFor(
          answer: woken(lat: fix.lat, lng: fix.lng),
          ride: ride,
          chain: chain(homeward),
        ),
        RelaunchAction.resume,
      );
    });

    test('A RIDER WHO WENT HOME ANOTHER WAY IS TOLD, NOT ANNOUNCED AT', () {
      // Andheri is on the Western line, nowhere near this journey, and it is
      // the same off-corridor case ride_resume_test.dart measures.
      final andheri = repo.stationsById['andheri']!;

      expect(
        relaunchActionFor(
          answer: woken(lat: andheri.lat, lng: andheri.lng),
          ride: ride,
          chain: chain(homeward),
        ),
        RelaunchAction.notify,
      );
    });

    test('woken for a ride, with no fix at all, is told rather than resumed',
        () {
      // The one combination that cannot be acted on. Notifying is honest;
      // starting a ride on no evidence is how a rider at home is announced at.
      expect(
        relaunchActionFor(
          answer: woken(),
          ride: ride,
          chain: chain(homeward),
        ),
        RelaunchAction.notify,
      );
    });

    test('a chain too short to have a corridor refuses, it does not resume',
        () {
      final fix = onTheTrain();

      expect(
        relaunchActionFor(
          answer: woken(lat: fix.lat, lng: fix.lng),
          ride: ride,
          chain: const [],
        ),
        RelaunchAction.notify,
      );
    });
  });

  group('a fix that will not state its accuracy', () {
    /// A NORTH-SOUTH SEGMENT, so that a probe due east of it sits at a
    /// perpendicular distance this test can state exactly.
    ///
    /// INVENTED COORDINATES ON PURPOSE, and it is the one place in this file
    /// where that is right: the question here is arithmetic (does an unstated
    /// accuracy widen the window by 150 m), not geography. Every other test
    /// runs on the generated station data.
    List<Station> northSouth() => [
      for (var i = 0; i < 2; i++)
        Station(
          id: 'probe$i',
          code: 'P$i',
          name: 'Probe $i',
          nameHi: 'Probe $i',
          nameMr: 'Probe $i',
          lat: 19.0 + i * 0.02,
          lng: 73.0,
          radiusM: 300,
        ),
    ];

    /// The probe's latitude: the midpoint of the segment, so the foot of the
    /// perpendicular lands inside it rather than on an endpoint.
    const probeLat = 19.01;

    /// A longitude exactly [metres] east of the segment at [probeLat].
    ///
    /// The same flat-earth projection distanceToCorridorM uses, at the same
    /// latitude, so "1600 m" here is the number that function will compute.
    double eastBy(double metres) =>
        73.0 +
        metres / (111320.0 * math.cos(probeLat * math.pi / 180.0));

    const inTheGap = 1600.0; // past 1500 m, inside 1500 + 150 m

    test('IT IS TREATED AS THE WORST FIX THIS APP WOULD EVER ACT ON', () {
      // 150 m is the app's own ceiling for a usable fix at 1 Hz. Widening is
      // the safe direction and it is a deliberate choice: being wrong this way
      // costs a little battery, being wrong the other way leaves a sleeping
      // rider with no alarm. See corridorToleranceM.
      final answer = RelaunchAnswer(
        launchedByLocation: true,
        lat: probeLat,
        lng: eastBy(inTheGap),
        // Core Location's "this reading is invalid".
        accuracyM: -1,
      );

      expect(
        relaunchActionFor(
          answer: answer,
          ride: ride,
          chain: northSouth(),
        ),
        RelaunchAction.resume,
      );
    });

    test('AND THE TEST CAN STILL FAIL: the same fix, stated as perfect', () {
      // Without the widening this point is off the corridor. If this ever
      // starts resuming, the constant above has stopped meaning anything.
      final answer = RelaunchAnswer(
        launchedByLocation: true,
        lat: probeLat,
        lng: eastBy(inTheGap),
        accuracyM: 0,
      );

      expect(
        relaunchActionFor(
          answer: answer,
          ride: ride,
          chain: northSouth(),
        ),
        RelaunchAction.notify,
      );
    });

    test('a missing accuracy is the same case as an invalid one', () {
      final answer = RelaunchAnswer(
        launchedByLocation: true,
        lat: probeLat,
        lng: eastBy(inTheGap),
      );

      expect(
        relaunchActionFor(
          answer: answer,
          ride: ride,
          chain: northSouth(),
        ),
        RelaunchAction.resume,
      );
    });
  });

  /// The lifeline's lifetime IS the in-flight flag, and nothing may write one
  /// without the other.
  ///
  /// A GUARD BECAUSE THE FAILURE IS INVISIBLE HERE. A lifeline left armed
  /// wakes a phone for a ride that is over; a lifeline never armed does
  /// nothing at all. Neither shows up on Android, in a test run, or on this
  /// desk. `writeRideInFlight` keeps the pair together by construction, and
  /// this stops a fourth call site from quietly going around it.
  group('THE FLAG AND THE LIFELINE CANNOT DRIFT', () {
    /// Every .dart file under lib/, comments stripped.
    String libSource() {
      final buffer = StringBuffer();
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//')) continue;
          buffer.writeln(line);
        }
      }
      return buffer.toString();
    }

    test('the flag is written in exactly ONE place', () {
      final writes = 'saveData(key: rideInFlightKey'.allMatches(libSource());
      expect(
        writes.length,
        1,
        reason: 'the only write belongs inside writeRideInFlight, which moves '
            'the lifeline with it',
      );
    });

    test('and that place moves the lifeline too', () {
      final lines = File(
        'lib/foreground/geofence_task_handler.dart',
      ).readAsLinesSync();
      final start = lines.indexWhere(
        (line) => line.contains('Future<void> writeRideInFlight('),
      );
      expect(start, isNonNegative, reason: 'writeRideInFlight must exist');
      // The function closes at column zero, being top-level.
      final end = lines.indexWhere((line) => line == '}', start);
      expect(end, isNonNegative, reason: 'writeRideInFlight must close');
      final body = lines.sublist(start, end).join(' ');

      expect(body, contains('saveData(key: rideInFlightKey'));
      expect(body, contains('setArmed(inFlight)'));
    });
  });
}
