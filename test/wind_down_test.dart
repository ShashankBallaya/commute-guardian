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

/// The alight dwell: one fix inside the fence at walking speed, the train
/// standing at the platform. Exit fixes only count after one of these.
void _alight(WindDown windDown, DateTime at) {
  windDown.onFix(
    lat: _digha.lat,
    lng: _digha.lng,
    accuracyM: 20,
    speedMps: 0.3,
    now: at,
  );
}

/// ~450 m north of the Digha station node: outside the 350 m fence, where
/// someone walking out of the station ends up a couple of minutes after
/// alighting.
const _outsideLat = 19.1848;
const _outsideLng = 72.9944301;

void main() {
  test('an alight dwell then two walking-speed fixes just outside the fence '
      'start the countdown with one spoken line', () {
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

    // The alight dwell: the train stopped at the platform (inside the
    // fence, walking speed). Without this, exit fixes never count.
    windDown.onFix(
      lat: _digha.lat,
      lng: _digha.lng,
      accuracyM: 20,
      speedMps: 0.3,
      now: _t0.add(const Duration(minutes: 1, seconds: 30)),
    );

    // First qualifying exit fix: suspicion, not proof. One noisy fix must
    // not end a ride.
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

  test('a train that blew through the destination and later crawled far '
      'away never triggers (the real 13 Jul Thakurli replay bug)', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    // The fast local crossed the fence at 22 m/s: no alight dwell exists.
    windDown.onFix(
      lat: _digha.lat,
      lng: _digha.lng,
      accuracyM: 13,
      speedMps: 22,
      now: _t0.add(const Duration(seconds: 5)),
    );

    // Minutes later the train crawls into the next station's approach at
    // walking speed, ~2 km from the destination (the real 18:26:33 fixes
    // were 1.4-1.6 m/s at that distance). Without the alight dwell and the
    // proximity band this ended Travel Mode 2.5 minutes before the
    // overshoot warning in the replay.
    for (var i = 0; i < 4; i++) {
      final crawl = windDown.onFix(
        lat: _digha.lat + 0.018,
        lng: _digha.lng,
        accuracyM: 13,
        speedMps: 1.5,
        now: _t0.add(Duration(minutes: 3, seconds: i * 5)),
      );
      expect(crawl, isEmpty,
          reason: 'a crawling train 2 km out is not a platform exit');
    }
    expect(windDown.isCountingDown, isFalse);
  });

  test('walking-speed fixes just outside the fence do not trigger without '
      'the alight dwell', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    // In the proximity band, at walking speed, but the train never stopped
    // inside the fence: a slow through-crawl, not an alighted rider.
    for (var i = 0; i < 3; i++) {
      final result = windDown.onFix(
        lat: _outsideLat,
        lng: _outsideLng,
        accuracyM: 20,
        speedMps: 1.4,
        now: _t0.add(Duration(minutes: 1, seconds: i * 5)),
      );
      expect(result, isEmpty);
    }
    expect(windDown.isCountingDown, isFalse);
  });

  test('the countdown expires 60 seconds after detection into an end action',
      () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(minutes: 1)));
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
    _alight(windDown, _t0.add(const Duration(minutes: 1)));
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
    _alight(windDown, _t0.add(const Duration(minutes: 1)));
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
    _alight(windDown, _t0.add(const Duration(minutes: 1)));

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

  test('vehicle speed after the alight disarms auto-off permanently (the '
      'crawling train that picked back up)', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(seconds: 30)));

    // The train the rider is still asleep on leaves the platform: a fix at
    // vehicle speed is proof the "alight" did not stick.
    final departing = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 12,
      now: _t0.add(const Duration(minutes: 1)),
    );
    expect(departing, isEmpty,
        reason: 'train-speed movement must keep Travel Mode (and the '
            'overshoot net) alive');

    // Walking-speed fixes later (the train crawling through a curve, or
    // the 13 Jul next-station crawl) must never trigger: recovery from a
    // missed stop is manual-end territory.
    for (var i = 0; i < 3; i++) {
      final crawl = windDown.onFix(
        lat: _outsideLat,
        lng: _outsideLng,
        accuracyM: 20,
        speedMps: 1.4,
        now: _t0.add(Duration(minutes: 2, seconds: i * 5)),
      );
      expect(crawl, isEmpty, reason: 'auto-off is disarmed for the ride');
    }
    expect(windDown.isCountingDown, isFalse);
  });

  test('vehicle speed during a live countdown cancels it silently', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(minutes: 1)));
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
    expect(windDown.isCountingDown, isTrue);

    // What read as a walking exit was a slow train now picking up speed:
    // the countdown must die before it ends Travel Mode under a sleeping
    // rider. Silent on purpose; the state flip reaches the notification
    // through the shell's isCountingDown mirror.
    final cancel = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 8,
      now: _t0.add(const Duration(minutes: 3, seconds: 20)),
    );
    expect(cancel, isEmpty);
    expect(windDown.isCountingDown, isFalse);

    // The dead countdown never fires its end.
    expect(
      windDown.onTick(_t0.add(const Duration(minutes: 5))),
      isEmpty,
    );
  });

  test('the real 18 Jul Kalyan walk-out fires the countdown inside the '
      '500 m fence (the ride where the old fence rule never armed)', () {
    // Kalyan, radiusM 500: the owner walked for ten minutes without ever
    // leaving the fence, and the fence-exit rule never fired. Every fix
    // below is real, from the 3T evening log.
    final kalyan = Station(
      id: 'kalyan',
      code: 'KYN',
      name: 'Kalyan',
      nameHi: 'Kalyan',
      nameMr: 'Kalyan',
      lat: 19.2358216,
      lng: 73.1308101,
      radiusM: 500,
    );
    final windDown = WindDown(destination: kalyan);
    windDown.onStationEvent(
      const Announcement(
        stationId: 'kalyan',
        kind: AnnouncementKind.arrival,
        text: 'You have arrived at your destination, Kalyan.',
      ),
      _t0,
    );

    // 22:06:31, the train standing at the platform: the alight anchor.
    windDown.onFix(
        lat: 19.23544, lng: 73.13129, accuracyM: 28, speedMps: 0.1, now: _t0);

    // 22:08:48, ~100 m into the walk: not far enough yet.
    final early = windDown.onFix(
        lat: 19.23567,
        lng: 73.13223,
        accuracyM: 7,
        speedMps: 1.2,
        now: _t0.add(const Duration(minutes: 2)));
    expect(early, isEmpty);

    // 22:09:44, a near-stationary dip at the stairs, still inside the
    // fence. If this re-anchored, the rest of the walk would measure from
    // here and never reach 150 m: the anchor must stay frozen.
    windDown.onFix(
        lat: 19.23594,
        lng: 73.13243,
        accuracyM: 5,
        speedMps: 0.4,
        now: _t0.add(const Duration(minutes: 3)));

    // 22:10:51 and 22:10:58, ~165 to 170 m from the anchor, both still
    // ~250 m INSIDE the fence: the countdown must start here.
    final first = windDown.onFix(
        lat: 19.23634,
        lng: 73.13254,
        accuracyM: 9,
        speedMps: 1.4,
        now: _t0.add(const Duration(minutes: 4)));
    expect(first, isEmpty);
    final second = windDown.onFix(
        lat: 19.23644,
        lng: 73.13252,
        accuracyM: 11,
        speedMps: 1.3,
        now: _t0.add(const Duration(minutes: 4, seconds: 7)));
    expect(second, hasLength(1));
    expect(second.single, isA<WindDownSpeak>());
    expect(windDown.isCountingDown, isTrue);
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
