import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:commute_guardian/services/wind_down.dart';
import 'package:flutter_test/flutter_test.dart';

/// Digha Gaon, the destination of the fixture ride the other engine tests
/// use, OSM coords from assets/stations/mumbai_suburban.json.
final _digha = Station(
  id: 'digha',
  code: 'DIGHA',
  name: 'Digha Gaon',
  nameHi: 'Digha Gaon',
  nameMr: 'Digha Gaon',
  lat: 19.1807762,
  lng: 72.9944301,
  radiusM: 350,
);

final _t0 = DateTime(2026, 7, 16, 19, 0, 0);

WindDown _newWindDown() => WindDown(destination: _digha);

Announcement _dighaArrival() => const Announcement(
      stationId: 'digha',
      kind: AnnouncementKind.arrival,
      text: 'You have arrived at your destination, Digha Gaon.',
    );

/// ~450 m north of the Digha station node: outside the 350 m fence, where
/// someone walking out of the station ends up a couple of minutes after
/// alighting.
const _outsideLat = 19.1848;
const _outsideLng = 72.9944301;

void main() {
  test('two walking-speed fixes outside the fence after arrival start the '
      'countdown with one spoken line', () {
    final windDown = _newWindDown();

    // Before arrival, fixes outside the fence mean nothing: the rider is
    // simply not there yet.
    final beforeArrival = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0,
    );
    expect(beforeArrival, isEmpty);

    windDown.onStationEvent(_dighaArrival(), _t0.add(const Duration(minutes: 1)));

    // First qualifying fix: suspicion, not proof. One noisy fix must not
    // end a ride.
    final first = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    expect(first, isEmpty);

    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.5,
      now: _t0.add(const Duration(minutes: 3, seconds: 5)),
    );
    expect(second, hasLength(1));
    expect(
      (second.single as WindDownSpeak).text,
      'Looks like you have left the station. Travel Mode will end in one '
      'minute. Use the notification to end it now, or keep it running '
      'longer.',
    );
    expect(windDown.isCountingDown, isTrue);
  });

  test('the countdown expires 60 seconds after detection into an end action',
      () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    final detected = _t0.add(const Duration(minutes: 3, seconds: 5));
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: detected,
    );

    expect(
      windDown.onTick(detected.add(const Duration(seconds: 59))),
      isEmpty,
    );

    final expiry = windDown.onTick(detected.add(const Duration(seconds: 60)));
    expect(expiry, hasLength(1));
    expect(expiry.single, isA<WindDownEnd>());

    // The end fires once; the shell's teardown takes it from here.
    expect(
      windDown.onTick(detected.add(const Duration(seconds: 65))),
      isEmpty,
    );
  });

  test('End now skips the wait; it does nothing when no countdown is live',
      () {
    final windDown = _newWindDown();

    // Pressing the button with nothing live must not end anything.
    expect(windDown.endNow(_t0), isEmpty);

    windDown.onStationEvent(_dighaArrival(), _t0);
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3, seconds: 5)),
    );

    final ended = windDown.endNow(_t0.add(const Duration(minutes: 3, seconds: 20)));
    expect(ended, hasLength(1));
    expect(ended.single, isA<WindDownEnd>());
    expect(windDown.isCountingDown, isFalse);

    // The countdown died with it: expiry never double-fires.
    expect(
      windDown.onTick(_t0.add(const Duration(minutes: 5))),
      isEmpty,
    );
  });

  test('Extend pushes the deadline 10 minutes from the press and speaks an '
      'ack; it does nothing with no countdown live', () {
    final windDown = _newWindDown();

    expect(windDown.extend(_t0), isEmpty);

    windDown.onStationEvent(_dighaArrival(), _t0);
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3, seconds: 5)),
    );

    final pressed = _t0.add(const Duration(minutes: 3, seconds: 30));
    final extended = windDown.extend(pressed);
    expect(extended, hasLength(1));
    expect(
      (extended.single as WindDownSpeak).text,
      'Travel Mode will stay on for ten more minutes.',
    );

    // The old 60 second deadline is gone; the new one runs from the press.
    expect(
      windDown.onTick(pressed.add(const Duration(minutes: 9, seconds: 59))),
      isEmpty,
    );
    final expiry = windDown.onTick(pressed.add(const Duration(minutes: 10)));
    expect(expiry, hasLength(1));
    expect(expiry.single, isA<WindDownEnd>());
  });

  test('a blackout-quality fix neither counts toward the exit streak nor '
      'resets it', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    // 600 m accuracy: this fix knows nothing, it must not decide anything
    // in either direction.
    final blackout = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 600,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3, seconds: 5)),
    );
    expect(blackout, isEmpty);

    // The next usable walking fix completes the streak of two.
    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 25,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3, seconds: 10)),
    );
    expect(second, hasLength(1));
    expect(second.single, isA<WindDownSpeak>());
  });

  test('leaving the fence at train speed never starts the countdown, and a '
      'train-speed fix resets the walking streak', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    // A sleeping rider carried past Digha exits the fence at train speed.
    for (var i = 0; i < 5; i++) {
      final result = windDown.onFix(
        lat: _outsideLat,
        lng: _outsideLng,
        accuracyM: 20,
        speedMps: 12,
        now: _t0.add(Duration(minutes: 1, seconds: i * 5)),
      );
      expect(result, isEmpty,
          reason: 'train-speed exit must keep Travel Mode (and the '
              'overshoot net) alive');
    }

    // One walking fix, then a train-speed fix (the train slowed through a
    // curve, then picked up again): the streak must not survive the gap.
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2)),
    );
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 12,
      now: _t0.add(const Duration(minutes: 2, seconds: 5)),
    );
    final afterReset = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2, seconds: 10)),
    );
    expect(afterReset, isEmpty,
        reason: 'the streak restarted; one walking fix is not proof');
  });

  test('a station event after arrival disarms wind-down permanently (the '
      'rider stayed on the train)', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    // The overshoot warning at the next station: the rider is provably
    // still aboard, and past-the-stop recovery is manual-end territory.
    windDown.onStationEvent(
      const Announcement(
        stationId: 'airoli',
        kind: AnnouncementKind.overshoot,
        text: 'You have passed your stop. Please alight here, at Airoli.',
      ),
      _t0.add(const Duration(minutes: 6)),
    );

    // Walking out of Airoli later must NOT trigger the Digha wind-down.
    for (var i = 0; i < 3; i++) {
      final result = windDown.onFix(
        lat: 19.1585231,
        lng: 72.9994023,
        accuracyM: 20,
        speedMps: 1.3,
        now: _t0.add(Duration(minutes: 10, seconds: i * 5)),
      );
      expect(result, isEmpty);
    }
  });
}
