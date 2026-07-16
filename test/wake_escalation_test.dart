import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:commute_guardian/services/wake_escalation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same OSM coords and Kalyan -> Digha ride as ride_progress_test.dart, so the
/// two engines are specified against the identical journey: Thane is the
/// interchange the route requires, Digha the destination, Airoli the
/// overshoot pin one past it.
Station _s(String id, String name, double lat, double lng, int radiusM) =>
    Station(
      id: id,
      code: id.toUpperCase(),
      name: name,
      nameHi: name,
      nameMr: name,
      lat: lat,
      lng: lng,
      radiusM: radiusM,
    );

final _chain = <Station>[
  _s('kalyan', 'Kalyan', 19.2358216, 73.1308101, 500),
  _s('thakurli', 'Thakurli', 19.22611, 73.09811, 400),
  _s('dombivli', 'Dombivli', 19.21815, 73.08673, 450),
  _s('kopar', 'Kopar', 19.21194, 73.07860, 400),
  _s('diva', 'Diva Junction', 19.1887564, 73.0414169, 400),
  _s('mumbra', 'Mumbra', 19.18979, 73.02325, 400),
  _s('kalwa', 'Kalwa', 19.1952243, 72.9963331, 400),
  _s('thane', 'Thane', 19.1864830, 72.9757664, 500),
  _s('digha', 'Digha Gaon', 19.1807762, 72.9944301, 350),
  _s('airoli', 'Airoli', 19.1585231, 72.9994023, 400),
];

/// An arbitrary wall-clock anchor; the engine only ever compares instants it
/// was handed, so the absolute value is meaningless.
final _t0 = DateTime(2026, 7, 16, 18, 0, 0);

Announcement _arrival(String stationId) => Announcement(
      stationId: stationId,
      kind: AnnouncementKind.arrival,
      text: 'Now approaching $stationId.',
    );

void main() {
  group('rung escalation while unacknowledged', () {
    test('25 seconds of silence after the check-in escalates to rung 1', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);

      // Just short of the check-in window: still waiting for the rider.
      final early = wake.onTick(_t0.add(const Duration(seconds: 24)));
      expect(early, isEmpty);

      final rung1 = wake.onTick(_t0.add(const Duration(seconds: 25)));
      expect(rung1, hasLength(2));
      expect(rung1[0], isA<Tone>());
      expect((rung1[0] as Tone).volume, 0.3);
      expect(rung1[1], isA<Speak>());
      expect(
        (rung1[1] as Speak).text,
        'Wake up. Your stop, Digha Gaon, is next.',
      );
    });

    test('later rungs climb every 15 seconds and repeat at full volume', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1

      // Rung interval measured from the previous rung, not from the tick
      // that happened to observe it.
      final early = wake.onTick(_t0.add(const Duration(seconds: 39)));
      expect(early, isEmpty);

      final rung2 = wake.onTick(_t0.add(const Duration(seconds: 40)));
      expect(rung2, hasLength(2));
      expect((rung2[0] as Tone).volume, 0.6);
      expect(rung2[1], isA<Vibrate>());

      final rung3 = wake.onTick(_t0.add(const Duration(seconds: 55)));
      expect(rung3, hasLength(2));
      expect((rung3[0] as Tone).volume, 1.0);
      expect(rung3[1], isA<Vibrate>());

      // Past the last configured rung the ladder keeps hammering at full.
      final rung4 = wake.onTick(_t0.add(const Duration(seconds: 70)));
      expect(rung4, hasLength(2));
      expect((rung4[0] as Tone).volume, 1.0);
      expect(rung4[1], isA<Vibrate>());
    });
  });

  group('acknowledgment', () {
    test('acknowledging during the check-in window stands the ladder down '
        'before any tone plays', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);

      final ack = wake.acknowledge(_t0.add(const Duration(seconds: 10)));
      expect(ack, hasLength(1));
      expect((ack.single as Speak).text, 'Good, you are awake.');

      // The ladder is dead: the rung that was due at +25s never fires.
      final later = wake.onTick(_t0.add(const Duration(seconds: 30)));
      expect(later, isEmpty);
    });

    test('acknowledging mid-climb stops the tone first', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1
      wake.onTick(_t0.add(const Duration(seconds: 40))); // rung 2

      final ack = wake.acknowledge(_t0.add(const Duration(seconds: 45)));
      expect(ack, hasLength(2));
      expect(ack[0], isA<StopTone>());
      expect((ack[1] as Speak).text, 'Good, you are awake.');

      expect(wake.onTick(_t0.add(const Duration(seconds: 55))), isEmpty);
    });

    test('an ack with no ladder live is a no-op, not an error', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      expect(wake.acknowledge(_t0), isEmpty);
    });
  });

  group('interchange ladders', () {
    test('a route-required interchange gets its own check-in, one station '
        'before it', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      final actions = wake.onStationEvent(_arrival('kalwa'), _t0);

      expect(actions, hasLength(1));
      expect(
        (actions.single as Speak).text,
        'Your train change at Thane is next. Tap your earphones, or press '
        'the I am awake button, to show you are awake.',
      );
    });

    test('the interchange ladder and the destination ladder run back to '
        'back, each against its own station', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // Interchange ladder: triggered at Kalwa, escalates once (pinning the
      // interchange wake-up copy), then the rider taps.
      wake.onStationEvent(_arrival('kalwa'), _t0);
      final rung1 = wake.onTick(_t0.add(const Duration(seconds: 25)));
      expect(
        (rung1[1] as Speak).text,
        'Wake up. Your train change at Thane is next.',
      );
      final ack = wake.acknowledge(_t0.add(const Duration(seconds: 30)));
      expect(ack[0], isA<StopTone>());

      // Reaching Thane itself now arms the DESTINATION ladder, because
      // Thane is also the station before Digha on this chain.
      final checkIn = wake.onStationEvent(
        _arrival('thane'),
        _t0.add(const Duration(minutes: 3)),
      );
      expect(checkIn, hasLength(1));
      expect(
        (checkIn.single as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );

      // And it escalates on its own clock, with destination copy.
      final destRung1 = wake.onTick(
        _t0.add(const Duration(minutes: 3, seconds: 25)),
      );
      expect((destRung1[0] as Tone).volume, 0.3);
      expect(
        (destRung1[1] as Speak).text,
        'Wake up. Your stop, Digha Gaon, is next.',
      );
    });

    test('no ladder fires for an ordinary intermediate station', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // Diva is one before Mumbra, which is critical for nobody on this
      // route. Ordinary stations get their announcement and nothing else.
      expect(wake.onStationEvent(_arrival('diva'), _t0), isEmpty);
      expect(wake.onStationEvent(_arrival('mumbra'), _t0), isEmpty);
    });
  });

  group('ETA trigger', () {
    test('a fix putting the stop under the lead window starts the check-in, '
        'even though the trigger station was never announced', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // Approaching Mumbra at 15 m/s: Digha is still ~3.2 km (~213 s) out,
      // comfortably beyond the 90 s lead window.
      final far = wake.onFix(
        lat: 19.18979,
        lng: 73.02325,
        accuracyM: 20,
        speedMps: 15,
        now: _t0,
      );
      expect(far, isEmpty);

      // Between Thane and Digha at 15 m/s: ~1.0 km, ~69 s out. The Kalwa
      // and Thane fences were never announced (jumped); the ETA zone is
      // what still wakes the rider in time.
      final near = wake.onFix(
        lat: 19.1836,
        lng: 72.9851,
        accuracyM: 20,
        speedMps: 15,
        now: _t0.add(const Duration(minutes: 2)),
      );
      expect(near, hasLength(1));
      expect(
        (near.single as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );

      // A late station event for the trigger station must not restart the
      // check-in over the ladder the ETA zone already started.
      final dupe = wake.onStationEvent(
        _arrival('thane'),
        _t0.add(const Duration(minutes: 2, seconds: 10)),
      );
      expect(dupe, isEmpty);
    });
  });

  group('dead-reckoning through a GPS blackout', () {
    test('when fixes stop, ticks project the last ETA forward and still '
        'fire the check-in', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // Last good fix near Mumbra: Digha ~213 s out at 15 m/s. Then the
      // GPS goes dark (the real 13 Jul Kalwa..Dombivli blackout pattern).
      wake.onFix(
        lat: 19.18979,
        lng: 73.02325,
        accuracyM: 20,
        speedMps: 15,
        now: _t0,
      );

      // 120 s into the blackout the projected remaining time is ~93 s,
      // still outside the 90 s lead window.
      expect(wake.onTick(_t0.add(const Duration(seconds: 120))), isEmpty);

      // At 125 s the projection crosses the window: the rider gets their
      // check-in from the timer alone, no fix required.
      final actions = wake.onTick(_t0.add(const Duration(seconds: 125)));
      expect(actions, hasLength(1));
      expect(
        (actions.single as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );
    });

    test('dead GPS with no prior usable fix stays quiet: the honest floor',
        () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // A blackout-quality fix sitting right on the destination must not
      // seed the projection either.
      wake.onFix(
        lat: 19.1807762,
        lng: 72.9944301,
        accuracyM: 600,
        speedMps: 15,
        now: _t0,
      );

      expect(wake.onTick(_t0.add(const Duration(minutes: 30))), isEmpty);
    });
  });

  group('calls suspend the wake clock', () {
    test('a call starting mid-ladder stops the tone and freezes escalation',
        () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1

      // On a call means awake (locked decision 8): the alarm must not
      // blast into the rider's phone conversation.
      final suspend = wake.onCallStateChanged(
        inCall: true,
        now: _t0.add(const Duration(seconds: 30)),
      );
      expect(suspend, hasLength(1));
      expect(suspend.single, isA<StopTone>());

      // The clock is frozen: rungs that would have fired stay silent.
      expect(wake.onTick(_t0.add(const Duration(seconds: 40))), isEmpty);
      expect(wake.onTick(_t0.add(const Duration(minutes: 2))), isEmpty);
    });

    test('hanging up with lead left gets a catch-up naming the stations the '
        'call swallowed, and the ladder arms from it', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // The 13 Jul return leg made this real: the owner's call around
      // Thakurli/Dombivli swallowed announcements. Here the call spans the
      // trigger station itself.
      wake.onCallStateChanged(inCall: true, now: _t0);
      expect(wake.onStationEvent(_arrival('kalwa'), _t0), isEmpty);
      expect(
        wake.onStationEvent(
          _arrival('thane'),
          _t0.add(const Duration(minutes: 2)),
        ),
        isEmpty,
        reason: 'the trigger firing mid-call must stay silent until hang-up',
      );

      final hangUp = _t0.add(const Duration(minutes: 3));
      final catchUp = wake.onCallStateChanged(inCall: false, now: hangUp);
      expect(catchUp, hasLength(1));
      expect(
        (catchUp.single as Speak).text,
        'While you were on your call, the train passed Kalwa and Thane. '
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );

      // The catch-up doubles as the check-in: silence still escalates.
      final rung1 =
          wake.onTick(hangUp.add(const Duration(seconds: 25)));
      expect((rung1[0] as Tone).volume, 0.3);
    });

    test('hanging up at or past the stop skips the gentle ramp and goes '
        'straight to a firm rung', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      wake.onCallStateChanged(inCall: true, now: _t0);
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onStationEvent(
        _arrival('digha'),
        _t0.add(const Duration(minutes: 5)),
      );

      // There is no lead left to be gentle with: full tone, vibration and
      // a direct instruction, all at once.
      final hangUp = wake.onCallStateChanged(
        inCall: false,
        now: _t0.add(const Duration(minutes: 5, seconds: 30)),
      );
      expect(hangUp, hasLength(3));
      expect((hangUp[0] as Tone).volume, 1.0);
      expect(hangUp[1], isA<Vibrate>());
      expect(
        (hangUp[2] as Speak).text,
        'While you were on your call, the train reached your stop, '
        'Digha Gaon. Get off the train now.',
      );

      // An ack still stands it down like any other rung.
      final ack = wake.acknowledge(
        _t0.add(const Duration(minutes: 5, seconds: 40)),
      );
      expect(ack[0], isA<StopTone>());
    });

    test('hanging up past the ceiling gets a firm rung with past-tense '
        'copy, never a claim the rider is at their stop', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // The call swallows everything: trigger, stop, and the overshoot pin.
      wake.onCallStateChanged(inCall: true, now: _t0);
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onStationEvent(
        _arrival('digha'),
        _t0.add(const Duration(minutes: 4)),
      );
      wake.onStationEvent(
        Announcement(
          stationId: 'airoli',
          kind: AnnouncementKind.overshoot,
          text: 'You have passed your stop. Please alight here, at Airoli.',
        ),
        _t0.add(const Duration(minutes: 8)),
      );

      final hangUp = wake.onCallStateChanged(
        inCall: false,
        now: _t0.add(const Duration(minutes: 8, seconds: 30)),
      );
      expect(hangUp, hasLength(3));
      expect((hangUp[0] as Tone).volume, 1.0);
      expect(hangUp[1], isA<Vibrate>());
      expect(
        (hangUp[2] as Speak).text,
        'While you were on your call, the train passed your stop, '
        'Digha Gaon. Please get off the train now.',
      );
    });

    test('the ETA and dead-reckoning triggers also hold during a call, then '
        'fire after hang-up', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // ETA seeded near Mumbra (~213 s out at 15 m/s), then a call starts.
      wake.onFix(
        lat: 19.18979,
        lng: 73.02325,
        accuracyM: 20,
        speedMps: 15,
        now: _t0,
      );
      wake.onCallStateChanged(
        inCall: true,
        now: _t0.add(const Duration(seconds: 30)),
      );

      // A fix arriving mid-call updates the seed silently instead of
      // starting a ladder into the rider's conversation: between Thane and
      // Digha this would have triggered (~69 s out).
      final midCallFix = wake.onFix(
        lat: 19.1836,
        lng: 72.9851,
        accuracyM: 20,
        speedMps: 15,
        now: _t0.add(const Duration(minutes: 2)),
      );
      expect(midCallFix, isEmpty);

      // The dead-reckoning countdown crossing the window mid-call stays
      // silent too.
      expect(wake.onTick(_t0.add(const Duration(minutes: 3))), isEmpty);

      // Hang-up, then the next tick delivers the held check-in.
      wake.onCallStateChanged(
        inCall: false,
        now: _t0.add(const Duration(minutes: 3, seconds: 30)),
      );
      final held = wake.onTick(
        _t0.add(const Duration(minutes: 3, seconds: 35)),
      );
      expect(held, hasLength(1));
      expect(
        (held.single as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );
    });
  });

  group('approach pings do not move the train', () {
    test('an approach at the ceiling station does not silence the ladder, '
        'and an approach at the trigger station does not start one', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      Announcement approach(String stationId) => Announcement(
            stationId: stationId,
            kind: AnnouncementKind.approach,
            text: 'Now approaching $stationId.',
          );

      // An approach ping for Kalwa's successor... Kalwa has no approach
      // fence, but Thane does, and Thane is the trigger for nothing while
      // the interchange target IS Thane. The honest early signal is the
      // ETA zone, not a fence 1.2 km out (arrival/passed only, per the
      // locked trigger definition).
      expect(wake.onStationEvent(approach('thane'), _t0), isEmpty);

      // Arm the Thane ladder properly, then let Digha's outer fence ping.
      // Digha is the Thane ladder's ceiling, but the train being 1 km short
      // of it must not stop the alarm a minute before the recovery point.
      wake.onStationEvent(_arrival('kalwa'), _t0);
      final ping = wake.onStationEvent(
        approach('digha'),
        _t0.add(const Duration(minutes: 2)),
      );
      expect(ping, isEmpty);

      // Still climbing: the ladder is alive after the ping.
      final rung = wake.onTick(_t0.add(const Duration(minutes: 2, seconds: 30)));
      expect(rung, isNotEmpty);

      // The real arrival is what stops it.
      final arrival = wake.onStationEvent(
        _arrival('digha'),
        _t0.add(const Duration(minutes: 3)),
      );
      expect(arrival.last, isA<HardStop>());
    });
  });

  group('ceiling', () {
    test('reaching one station past the stop hard-stops an unacknowledged '
        'ladder', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1

      // The rider slept through Digha; the train reaches Airoli, where
      // RideProgress's overshoot announcement already says alight here. The
      // ladder's job is over: silence the alarm and give up.
      final actions = wake.onStationEvent(
        _arrival('airoli'),
        _t0.add(const Duration(minutes: 4)),
      );
      expect(actions, hasLength(2));
      expect(actions[0], isA<StopTone>());
      expect(actions[1], isA<HardStop>());

      expect(wake.onTick(_t0.add(const Duration(minutes: 5))), isEmpty);
    });
  });

  group('ladder trigger by previous-station detection', () {
    test('announcing the station before the destination starts the check-in',
        () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      final actions = wake.onStationEvent(_arrival('thane'), _t0);

      expect(actions, hasLength(1));
      final speak = actions.single;
      expect(speak, isA<Speak>());
      expect(
        (speak as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );
    });
  });
}
