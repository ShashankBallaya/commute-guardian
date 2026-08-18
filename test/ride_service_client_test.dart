import 'dart:io';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/services/wind_down.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wire contract with the service isolate.
///
/// These payload shapes are written by lib/foreground/geofence_task_handler.dart
/// in the OTHER isolate, so nothing type-checks the crossing. This test is the
/// only thing standing between a renamed key and a feature that silently stops
/// working on a locked phone.
void main() {
  group('parseServiceData', () {
    test('a ride log line becomes a log event', () {
      final events = parseServiceData({'message': 'CLIP shahad__approach.wav'});
      expect(events, hasLength(1));
      expect(
        (events.single as ServiceLogged).message,
        'CLIP shahad__approach.wav',
      );
    });

    test('the wake ladder and wind-down flags carry both polarities', () {
      expect(
        (parseServiceData({'wakeLadderLive': true}).single as WakeLadderChanged)
            .live,
        isTrue,
      );
      expect(
        (parseServiceData({'wakeLadderLive': false}).single
                as WakeLadderChanged)
            .live,
        isFalse,
      );
      expect(
        (parseServiceData({'windDownLive': true}).single as WindDownChanged)
            .live,
        isTrue,
      );
    });

    test('the wind-down deadline travels with its liveness', () {
      // Screen 5 draws real seconds. Reconstructing the deadline on the UI side
      // would show a fresh minute to a rider who has five seconds left, and
      // would miss an Extend entirely.
      final counting =
          parseServiceData({
                'windDownLive': true,
                'windDownEndsAtMs': DateTime.utc(
                  2026,
                  8,
                  4,
                  12,
                  30,
                ).millisecondsSinceEpoch,
                'windDownWindowS': 600,
              }).single
              as WindDownChanged;
      expect(counting.live, isTrue);
      expect(counting.endsAt, DateTime.utc(2026, 8, 4, 12, 30).toLocal());
      expect(counting.window, const Duration(minutes: 10));
    });

    test('a stopped countdown carries no deadline, sent or stored', () {
      // The store has no null, so it holds 0 for "nothing is counting". Both
      // spellings have to mean the same thing or a finished countdown would
      // come back as a deadline in 1970.
      final sent =
          parseServiceData({
                'windDownLive': false,
                'windDownEndsAtMs': null,
              }).single
              as WindDownChanged;
      expect(sent.endsAt, isNull);

      final stored =
          parseServiceData({
                'windDownLive': false,
                'windDownEndsAtMs': 0,
              }).single
              as WindDownChanged;
      expect(stored.endsAt, isNull);
    });

    test('an older payload with no deadline still parses', () {
      // A service isolate can outlive an app update in the field.
      final event =
          parseServiceData({'windDownLive': true}).single as WindDownChanged;
      expect(event.live, isTrue);
      expect(event.endsAt, isNull);
      expect(event.window, WindDown.countdown);
    });

    test('the destination arrival is announced, not only stored', () {
      // It was store-only until 4 Aug 2026, which meant nothing on the UI side
      // could ever notice the rider had arrived while the ride was still
      // running. Screen 5 opens on this.
      expect(
        parseServiceData({'destinationReached': true}).single,
        isA<DestinationReached>(),
      );
      expect(parseServiceData({'destinationReached': false}), isEmpty);
    });

    test('the station the rider alights at crosses the boundary', () {
      // The 4 Aug open item. WindDown moves its exit watch to an overshoot pin
      // and Screen 5 named the destination anyway, so a rider carried past
      // Shahad and standing at Ambivli would have been told they had arrived
      // at Shahad.
      final event = parseServiceData({'alightStationId': 'ambivli'}).single;
      expect(event, isA<AlightingAt>());
      expect((event as AlightingAt).stationId, 'ambivli');
    });

    test('an empty alight station is no opinion, not a station', () {
      // saveData has no null, so the teardown writes '' to clear it. Reading
      // that as a station id would have Screen 5 look up a station that does
      // not exist on the NEXT ride.
      expect(parseServiceData({'alightStationId': ''}), isEmpty);
    });

    test('a tone command defaults to full volume when none is sent', () {
      final withVolume =
          parseServiceData({
                'toneCommand': 'startTone',
                'toneVolume': 0.3,
              }).single
              as ToneCommanded;
      expect(withVolume.command, 'startTone');
      expect(withVolume.volume, 0.3);

      // A stop carries no volume. Defaulting to 1.0 rather than 0.0 matters:
      // a wrong default here would silence the alarm, which is the one failure
      // this app exists to prevent.
      final noVolume =
          parseServiceData({'toneCommand': 'stopTone'}).single as ToneCommanded;
      expect(noVolume.volume, 1.0);
    });

    test('rideEnded fires only when true, never merely present', () {
      expect(
        parseServiceData({'rideEnded': true}).single,
        isA<RideEndedByService>(),
      );
      expect(parseServiceData({'rideEnded': false}), isEmpty);
    });

    test('A FIX CARRIES SPEED, and -1 is not a speed', () {
      // Both platforms report a negative speed to mean "no reading", and every
      // desk log this project has is full of `speed -1.0m/s`. A screen that
      // renders that shows a train doing minus one; a screen that clamps it to
      // zero tells a rider on a moving train they are stopped. The sentinel
      // dies at this boundary, once.
      final moving =
          parseServiceData({
                'fixLat': 19.24,
                'fixLng': 73.15,
                'fixAccuracyM': 8.0,
                'fixSpeedMs': 29.9,
              }).single
              as ServiceFix;
      expect(moving.speedMs, 29.9);
      // 107.6 km/h is the fastest this project has measured on a real ride.
      expect(moving.speedKmh, closeTo(107.6, 0.1));

      final unknown =
          parseServiceData({
                'fixLat': 19.24,
                'fixLng': 73.15,
                'fixAccuracyM': 8.0,
                'fixSpeedMs': -1.0,
              }).single
              as ServiceFix;
      expect(unknown.speedMs, isNull);
      expect(unknown.speedKmh, isNull);
    });

    test('and a fix WITHOUT speed is still a fix', () {
      // Speed is optional on the wire, unlike lat, lng and accuracy. An older
      // service or a silent platform must cost the rider a speed reading and
      // nothing else: the chip still has to move.
      final fix =
          parseServiceData({
                'fixLat': 19.24,
                'fixLng': 73.15,
                'fixAccuracyM': 8.0,
              }).single
              as ServiceFix;
      expect(fix.lat, 19.24);
      expect(fix.speedMs, isNull);
    });

    test('A REAL ZERO IS A READING, and it means stopped', () {
      // The one case the null sentinel must not swallow: a train standing at a
      // platform reports 0.0, which is true and is not the same as "unknown".
      final stopped =
          parseServiceData({
                'fixLat': 19.24,
                'fixLng': 73.15,
                'fixAccuracyM': 8.0,
                'fixSpeedMs': 0.0,
              }).single
              as ServiceFix;
      expect(stopped.speedMs, 0.0);
      expect(stopped.speedKmh, 0.0);
    });

    test('a fix needs all three parts, or it is not a fix', () {
      final fix =
          parseServiceData({
                'fixLat': 19.2358216,
                'fixLng': 73.1308101,
                'fixAccuracyM': 13,
              }).single
              as ServiceFix;
      expect(fix.lat, 19.2358216);
      expect(fix.lng, 73.1308101);
      expect(fix.accuracyM, 13.0);

      // A partial fix is dropped rather than half-applied: a fix with no
      // accuracy cannot be gated against the 150 m blackout threshold.
      expect(parseServiceData({'fixLat': 19.23, 'fixLng': 73.13}), isEmpty);
      expect(parseServiceData({'fixLat': 19.23, 'fixAccuracyM': 13}), isEmpty);
    });

    test('one payload can carry several events, and order is stable', () {
      // The service sends the fix and its log line together on every tick.
      final events = parseServiceData({
        'message': 'FIX lat 19.23, lng 73.13',
        'fixLat': 19.23,
        'fixLng': 73.13,
        'fixAccuracyM': 11,
      });
      expect(events, hasLength(2));
      expect(events.first, isA<ServiceLogged>());
      expect(events.last, isA<ServiceFix>());
    });

    test('junk and unknown payloads are ignored, not thrown on', () {
      expect(parseServiceData('a bare string'), isEmpty);
      expect(parseServiceData(42), isEmpty);
      expect(parseServiceData(<String, dynamic>{}), isEmpty);
      expect(
        parseServiceData({'somethingNewer': 'from a future service'}),
        isEmpty,
      );
    });
  });

  group('A NEW RIDE STARTS WITH NO PROGRESS', () {
    // FOUND 17 AUG 2026, while building the resume, and deliberately left out
    // of those commits because it changes ordinary rides.
    //
    // Progress is ride-scoped state written by the SERVICE and read back by a
    // UI the OS recreated. Nothing cleared it at Start, so it outlived the ride
    // that wrote it: the next journey read the PREVIOUS one's index until its
    // own first station passed, and Screen 4 drew a rider partway down a chain
    // they had only just started. The plugin cannot run under a test binding,
    // so this reads the source, like the isolate-boundary guard next door.
    final source = File(
      'lib/services/ride_service_client.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    /// Whether [code] really WRITES both keys, comments discounted.
    ///
    /// COMMENTS ARE STRIPPED ON PURPOSE. Five guards in this project have
    /// passed on prose that merely mentioned the thing they were meant to
    /// find, and both keys below are named in the comment beside them.
    bool clearsProgress(String code) {
      final stripped = code
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n')
          .replaceAll(RegExp(r'\s+'), ' ');
      return stripped.contains('saveData(key: reachedIndexKey, value: -1)') &&
          stripped.contains('saveData(key: atStationKey, value: false)');
    }

    String startRideBody() {
      final start = source.indexOf('Future<bool> startRide({');
      expect(start, greaterThan(-1), reason: 'startRide is gone');
      final end = source.indexOf(
        '/// The rider pressed End journey.',
        start,
      );
      expect(end, greaterThan(start), reason: 'startRide has no end');
      return source.substring(start, end);
    }

    test('it clears the progress the LAST ride left in the store', () {
      expect(
        clearsProgress(startRideBody()),
        isTrue,
        reason:
            'without this a new ride reads the previous ride index until its '
            'own first station passes, and the at-station flag with it',
      );
    });

    test('AND THAT GUARD CAN STILL FAIL', () {
      // The rule this project keeps relearning: a guard nobody has watched
      // fail is not a guard.
      const mentionedOnly =
          'Future<bool> startRide({}) async {\n'
          '  // Clears saveData(key: reachedIndexKey, value: -1) and\n'
          '  // saveData(key: atStationKey, value: false) at the top.\n'
          '  await FlutterForegroundTask.saveData(key: originIdKey, value: 1);\n'
          '}';
      expect(clearsProgress(mentionedOnly), isFalse);
    });
  });
}
