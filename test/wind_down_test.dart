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

/// Airoli, the overshoot pin of the fixture ride: where a rider carried past
/// Digha is told to alight. OSM coords from the same station data.
final _airoli = Station(
  id: 'airoli',
  code: 'AIRL',
  name: 'Airoli',
  nameHi: 'Airoli',
  nameMr: 'Airoli',
  lat: 19.1585231,
  lng: 72.9994023,
  radiusM: 400,
);

final _t0 = DateTime(2026, 7, 16, 19, 0, 0);

WindDown _newWindDown() =>
    WindDown(destination: _digha, overshootStations: [_airoli]);

Announcement _airoliOvershoot() => const Announcement(
      stationId: 'airoli',
      kind: AnnouncementKind.overshoot,
      text: 'You have passed your stop. It is alright. Please alight here, '
          'at Airoli.',
    );

/// ~180 m north of the Airoli node, the same shape as [_outsideLat] is for
/// Digha: past the 150 m exit walk, and reachable on foot in the time the
/// fixtures allow.
const _airoliOutsideLat = 19.16014;
const _airoliOutsideLng = 72.9994023;

/// The alight dwell at the overshoot pin: one in-fence fix slow enough to be
/// a stopped train, which is what moves the anchor to this station.
void _alightAtAiroli(WindDown windDown, DateTime at) {
  windDown.onFix(
    lat: _airoli.lat,
    lng: _airoli.lng,
    accuracyM: 20,
    speedMps: 0.3,
    now: at,
  );
}

/// Two walking-speed fixes 180 m off the Airoli anchor: the platform exit.
/// Returns what the second one produced, which is where the countdown starts.
List<WindDownAction> _walkOutOfAiroli(WindDown windDown, DateTime from) {
  windDown.onFix(
    lat: _airoliOutsideLat,
    lng: _airoliOutsideLng,
    accuracyM: 20,
    speedMps: 1.3,
    now: from.add(const Duration(seconds: 90)),
  );
  return windDown.onFix(
    lat: _airoliOutsideLat,
    lng: _airoliOutsideLng,
    accuracyM: 20,
    speedMps: 1.3,
    now: from.add(const Duration(seconds: 95)),
  );
}

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

/// ~180 m north of the Digha station node: past the 150 m exit-walk threshold
/// from an anchor at the platform, and a distance a real walker covers in the
/// minute-plus these fixtures allow (450 m in 90 s, the old value, was 5 m/s,
/// not a walk, and the time-plausibility guard rightly rejects it).
const _outsideLat = 19.18240;
const _outsideLng = 72.9944301;


/// A wind-down that produced only [WindDownNote]s has done nothing the rider
/// can hear: notes are diagnostics written to the ride log, not behaviour.
/// Assertions say "silent", not "empty", so adding a diagnostic can never look
/// like a behaviour change.
Matcher get silent => everyElement(isA<WindDownNote>());

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
    expect(beforeArrival, silent);

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
    expect(first, silent);

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

  test('one jog-speed fix in the ambiguous band breaks the streak but does '
      'not cost a real walker their auto-off', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(seconds: 30)));

    // 3.0 m/s: too fast for a walk, too slow to prove a vehicle. GPS throws
    // this at real walkers, so a single one must only reset the streak.
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 3.0,
      now: _t0.add(const Duration(minutes: 2)),
    );

    // Walking again, so the countdown is still reachable: not disarmed.
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2, seconds: 5)),
    );
    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2, seconds: 10)),
    );
    expect(second, hasLength(1));
    expect(windDown.isCountingDown, isTrue);
  });

  test('two consecutive ambiguous-band fixes disarm auto-off, closing the '
      'sparse-sampling hole under a departing train', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0);

    // A train accelerating off the platform holds above walking speed for a
    // continuous run of fixes on its way up. Two in a row disarm: sustained
    // motion, not a lone spike. The run has to reach past vehicleMinElapsed
    // from the anchor before the recession counts at all, and it has to stay
    // CONTINUOUS to get there: a single long gap would both break the streak
    // and mark the anchor for re-setting.
    for (var t = 5; t <= 40; t += 5) {
      windDown.onFix(
        lat: _outsideLat,
        lng: _outsideLng,
        accuracyM: 20,
        speedMps: 3.2,
        now: _t0.add(Duration(seconds: t)),
      );
    }

    // Now two clean walking-speed fixes far from the anchor. Auto-off is
    // gone for the ride, so they must produce nothing.
    final first = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3)),
    );
    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 3, seconds: 5)),
    );
    expect(first, silent);
    expect(second, silent);
    expect(windDown.isCountingDown, isFalse);
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
      expect(crawl, silent,
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
      expect(result, silent);
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
      silent,
    );

    final expiry = windDown.onTick(detected.add(const Duration(seconds: 60)));
    expect(expiry, hasLength(1));
    expect(expiry.single, isA<WindDownEnd>());

    // The end fires once; the shell's teardown takes it from here.
    expect(
      windDown.onTick(detected.add(const Duration(seconds: 65))),
      silent,
    );
  });

  test('End now skips the wait; it does nothing when no countdown is live',
      () {
    final windDown = _newWindDown();

    // Pressing the button with nothing live must not end anything.
    expect(windDown.endNow(_t0), silent);

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
      silent,
    );
  });

  test('Extend pushes the deadline 10 minutes from the press and speaks an '
      'ack; it does nothing with no countdown live', () {
    final windDown = _newWindDown();

    expect(windDown.extend(_t0), silent);

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
      silent,
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
    expect(blackout, silent);

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
    _alight(windDown, _t0);

    // The train the rider is still asleep on leaves the platform. Two
    // continuous vehicle-speed fixes past vehicleMinElapsed are proof the
    // "alight" did not stick; the run before them keeps the stream continuous
    // so the streak can build.
    for (var t = 5; t <= 35; t += 5) {
      windDown.onFix(
        lat: _outsideLat,
        lng: _outsideLng,
        accuracyM: 20,
        speedMps: 12,
        now: _t0.add(Duration(seconds: t)),
      );
    }
    final departing = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 12,
      now: _t0.add(const Duration(seconds: 40)),
    );
    expect(departing, silent,
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
      expect(crawl, silent, reason: 'auto-off is disarmed for the ride');
    }
    expect(windDown.isCountingDown, isFalse);
  });

  test('an invalid speed reading cannot set the alight anchor (the 20 Jul '
      'iPhone Ambivli overshoot failure)', () {
    // Real shape of the 20 Jul iPhone return leg. Destination Ambivli, the
    // rider riding one stop PAST to Shahad to test the overshoot net. The
    // alight anchor was set 36 m inside the Ambivli fence on a fix whose
    // speed was -1.0, the location provider's sentinel for "speed unknown".
    // -1.0 slipped under the <= 1.0 stationary check, so a fix that proved
    // nothing about motion became the anchor. The train then carried the
    // rider past, the drift read as a 150 m walk over three minutes, and
    // wind-down ended Travel Mode before Shahad: the overshoot warning never
    // fired. An unknown speed is not proof of a stop.
    final ambivli = Station(
      id: 'ambivli',
      code: 'ABY',
      name: 'Ambivli',
      nameHi: 'Ambivli',
      nameMr: 'Ambivli',
      lat: 19.2682913,
      lng: 73.1722459,
      radiusM: 350,
    );
    final windDown = WindDown(destination: ambivli);
    windDown.onStationEvent(
      const Announcement(
        stationId: 'ambivli',
        kind: AnnouncementKind.arrival,
        text: 'You have arrived at your destination, Ambivli.',
      ),
      _t0,
    );

    // The would-be anchor: 36 m inside the fence, speed -1.0 (unknown). This
    // must not anchor. It is the only in-fence low-speed fix; the train then
    // moves away toward Shahad, so nothing after it is inside the fence.
    windDown.onFix(
      lat: 19.26862,
      lng: 73.17227,
      accuracyM: 20,
      speedMps: -1.0,
      now: _t0.add(const Duration(seconds: 5)),
    );

    // Two walking-speed fixes ~450 m past Ambivli toward Shahad, well over
    // 150 m from the would-be anchor and spread over enough time to look like
    // a walk. With no anchor set, they must produce nothing.
    final walk1 = windDown.onFix(
      lat: 19.26424,
      lng: 73.1722459,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 4)),
    );
    final walk2 = windDown.onFix(
      lat: 19.26424,
      lng: 73.1722459,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 4, seconds: 5)),
    );
    expect(walk1, silent);
    expect(walk2, silent,
        reason: 'an unknown-speed fix never anchored, so nothing can arm');
    expect(windDown.isCountingDown, isFalse);
  });

  test('an implausibly fast jump between two fixes is a GPS glitch, not a '
      'walk (the 20 Jul 3T Asangaon 157 m/s teleport)', () {
    // The 3T false fire: the alight anchor sat 202 m out, then the very next
    // fix one second later was 157 m away, both reporting speed 0 through a
    // degraded stream. 157 m in one second is 157 m/s. Two such fixes cleared
    // the 150 m walk threshold instantly and ended Travel Mode two seconds
    // after arrival. A step the rider could not physically have walked must
    // not count toward the exit.
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(seconds: 30)));

    // Two fixes 150 m+ from the anchor but only ONE SECOND apart: a teleport,
    // not a walk. Reported speed is the degraded stream's bogus 0.
    final jump1 = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 100,
      speedMps: 0.0,
      now: _t0.add(const Duration(minutes: 1)),
    );
    final jump2 = windDown.onFix(
      lat: _outsideLat + 0.0001,
      lng: _outsideLng,
      accuracyM: 100,
      speedMps: 0.0,
      now: _t0.add(const Duration(minutes: 1, seconds: 1)),
    );
    expect(jump1, silent);
    expect(jump2, silent,
        reason: '150 m in 1 s is not a walk; the exit must not arm');
    expect(windDown.isCountingDown, isFalse);
  });

  test('a lone fast reading across a GPS gap does not disarm the genuine '
      'walk-off (the 20 Jul 3T Shahad walk to parking)', () {
    // The one real walk-off of the 20 Jul ride, and it never fired. The rider
    // alighted at Shahad and walked to the parking, but 15 s after arrival a
    // GPS gap ended with the position 135 m from the anchor, and the provider
    // reported 6.2 m/s for that one fix, the gap-crossing distance over time,
    // not a vehicle. The old guard disarmed on that single reading and the
    // 340 m walk that followed never armed the countdown. A fast reading that
    // comes across a gap, and does not persist, is not a departing train.
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0.add(const Duration(seconds: 2)));

    // 15 s gap, then a fix 135 m from the anchor reporting 6.2 m/s: the gap
    // artifact. It must not disarm.
    windDown.onFix(
      lat: 19.18198, // ~135 m north of the Digha anchor at _alight
      lng: 72.9944301,
      accuracyM: 55,
      speedMps: 6.2,
      now: _t0.add(const Duration(seconds: 17)),
    );

    // The walk to parking: two continuous walking fixes past 150 m from the
    // anchor, over enough time to be a real walk. The countdown must arm.
    final first = windDown.onFix(
      lat: _outsideLat, // ~180 m from the anchor
      lng: _outsideLng,
      accuracyM: 12,
      speedMps: 1.2,
      now: _t0.add(const Duration(minutes: 2)),
    );
    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 10,
      speedMps: 1.3,
      now: _t0.add(const Duration(minutes: 2, seconds: 6)),
    );
    expect(first, silent);
    expect(second, hasLength(1),
        reason: 'the genuine walk-off must fire; the gap artifact must not '
            'have disarmed it');
    expect(windDown.isCountingDown, isTrue);
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

    // What read as a walking exit was a slow train, and now the rider is
    // found far past the anchor, faster than any walk could have carried
    // them: two continuous fixes of that recession prove a vehicle and the
    // countdown must die before it ends Travel Mode under a sleeping rider.
    // Silent on purpose; the state flip reaches the notification through the
    // isCountingDown mirror. ~700 m north of Digha.
    const farLat = 19.18708;
    windDown.onFix(
      lat: farLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 8,
      now: _t0.add(const Duration(minutes: 3, seconds: 10)),
    );
    final cancel = windDown.onFix(
      lat: farLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 8,
      now: _t0.add(const Duration(minutes: 3, seconds: 15)),
    );
    expect(cancel, silent);
    expect(windDown.isCountingDown, isFalse);

    // The dead countdown never fires its end.
    expect(
      windDown.onTick(_t0.add(const Duration(minutes: 5))),
      silent,
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
    expect(early, silent);

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
    expect(first, silent);
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

  test('GPS settling in the seconds after the anchor is not a departing '
      'train (the 22 Jul iPhone Shahad case)', () {
    // The real numbers: anchored at Shahad 15:47:17, disarmed 15:47:25 on
    // "receded 61 m in 7s, over the 28 m a walk allows". 61 m is the fix
    // stream settling, not a train. Because the disarm is permanent, those
    // 8 seconds cost the rider auto-off for the rest of the journey, and he
    // walked home with the phone still streaming.
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    _alight(windDown, _t0);

    // 61 m from the anchor, 7 s later: over 4 m/s on paper, meaningless in
    // practice at this baseline.
    const jitterLat = 19.18133; // ~61 m north of the Digha node
    for (final t in [7, 12]) {
      final r = windDown.onFix(
        lat: jitterLat,
        lng: _digha.lng,
        accuracyM: 20,
        speedMps: 0.4,
        now: _t0.add(Duration(seconds: t)),
      );
      expect(r, silent);
    }

    // The rider then genuinely walks out, and auto-off must still be alive.
    windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2)),
    );
    final second = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.4,
      now: _t0.add(const Duration(minutes: 2, seconds: 5)),
    );
    expect(second.whereType<WindDownSpeak>(), hasLength(1));
  });

  test('an overshoot re-arms the exit watch at the overshoot station', () {
    // Was the opposite assertion until the 22 Jul ride: an overshoot used to
    // disarm auto-off for the whole ride, so the owner walked home from
    // Shahad with both phones still streaming GPS and had to end the journey
    // by hand. The still-aboard reasoning was right; it just never let go
    // once the overshot rider finally got off.
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    windDown.onStationEvent(
      _airoliOvershoot(),
      _t0.add(const Duration(minutes: 6)),
    );

    final atAiroli = _t0.add(const Duration(minutes: 7));
    _alightAtAiroli(windDown, atAiroli);

    final result = _walkOutOfAiroli(windDown, atAiroli);
    expect(result.whereType<WindDownSpeak>(), hasLength(1));
  });

  test('the overshoot re-arm survives the vehicle disarm that precedes it '
      '(the 22 Jul Kalyan-to-Shahad case)', () {
    // The real sequence: destination reached, then the train pulls out with
    // the rider still aboard, which disarms on recession BEFORE the overshoot
    // announcement ever fires. If the re-arm respected that disarm it would
    // never run on a real overshoot, which is the only way this happens.
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    _alight(windDown, _t0);
    // Receding far faster than a walk, two continuous fixes: the train left.
    windDown.onFix(
      lat: 19.1834712, // 300 m north of Digha
      lng: _digha.lng,
      accuracyM: 20,
      speedMps: 0.0,
      now: _t0.add(const Duration(seconds: 5)),
    );
    windDown.onFix(
      lat: 19.1861662, // 600 m north of Digha
      lng: _digha.lng,
      accuracyM: 20,
      speedMps: 0.0,
      now: _t0.add(const Duration(seconds: 10)),
    );

    windDown.onStationEvent(
      _airoliOvershoot(),
      _t0.add(const Duration(minutes: 6)),
    );

    final atAiroli = _t0.add(const Duration(minutes: 7));
    _alightAtAiroli(windDown, atAiroli);

    final result = _walkOutOfAiroli(windDown, atAiroli);
    expect(result.whereType<WindDownSpeak>(), hasLength(1));
  });

  test('after the re-arm the old destination is no longer the exit station',
      () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);
    windDown.onStationEvent(
      _airoliOvershoot(),
      _t0.add(const Duration(minutes: 6)),
    );

    // A dwell and a walk back at Digha: the anchor moved to Airoli, so these
    // are just a rider wandering 2.7 km from the station that now matters.
    final atDigha = _t0.add(const Duration(minutes: 7));
    _alight(windDown, atDigha);
    final result = windDown.onFix(
      lat: _outsideLat,
      lng: _outsideLng,
      accuracyM: 20,
      speedMps: 1.3,
      now: atDigha.add(const Duration(seconds: 90)),
    );
    expect(result, silent);
  });

  test('a non-overshoot station event after arrival still disarms wind-down '
      'permanently (the rider stayed on the train)', () {
    final windDown = _newWindDown();
    windDown.onStationEvent(_dighaArrival(), _t0);

    // A plain arrival further down the line is not a pin telling the rider to
    // get off, so the original reasoning stands: still aboard, manual end.
    windDown.onStationEvent(
      const Announcement(
        stationId: 'airoli',
        kind: AnnouncementKind.arrival,
        text: 'Now approaching Airoli.',
      ),
      _t0.add(const Duration(minutes: 6)),
    );

    final atAiroli = _t0.add(const Duration(minutes: 7));
    _alightAtAiroli(windDown, atAiroli);
    expect(_walkOutOfAiroli(windDown, atAiroli), silent);
  });
}
