import 'package:commute_guardian/services/ride_service_client.dart';
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
      expect((events.single as ServiceLogged).message,
          'CLIP shahad__approach.wav');
    });

    test('the wake ladder and wind-down flags carry both polarities', () {
      expect(
        (parseServiceData({'wakeLadderLive': true}).single
                as WakeLadderChanged)
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

    test('a tone command defaults to full volume when none is sent', () {
      final withVolume =
          parseServiceData({'toneCommand': 'startTone', 'toneVolume': 0.3})
              .single as ToneCommanded;
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
      expect(parseServiceData({'rideEnded': true}).single,
          isA<RideEndedByService>());
      expect(parseServiceData({'rideEnded': false}), isEmpty);
    });

    test('a fix needs all three parts, or it is not a fix', () {
      final fix = parseServiceData({
        'fixLat': 19.2358216,
        'fixLng': 73.1308101,
        'fixAccuracyM': 13,
      }).single as ServiceFix;
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
      expect(parseServiceData({'somethingNewer': 'from a future service'}),
          isEmpty);
    });
  });
}
