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

/// The Dadar complex as the planner emits it for a Western -> Central ride
/// (Churchgate -> Kalyan alights at Dadar Western and walks to Dadar Central).
/// Real OSM coords: the two halves are 207 m apart, both behind 450 m fences.
final _dadarChain = <Station>[
  _s('prabhadevi', 'Prabhadevi', 19.00747, 72.83590, 350),
  _s('dadar_western', 'Dadar', 19.01923, 72.84285, 450),
  _s('dadar', 'Dadar', 19.01738, 72.84303, 450),
  _s('matunga', 'Matunga', 19.02744, 72.85015, 350),
  _s('sion', 'Sion', 19.04652, 72.86328, 350),
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
  _wakeToggleTests();
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
        'Wake up! Wake up. Your stop, Digha Gaon, is next.',
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
      expect(wake.isLadderLive, isFalse);

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
        'Wake up! Wake up. Your train change at Thane is next.',
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
        'Wake up! Wake up. Your stop, Digha Gaon, is next.',
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

    test('dead GPS with no prior usable fix stays quiet: the honest floor', () {
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

    /// THE 21 AUG 2026 RIDE, which is why the coast is bounded at all.
    ///
    /// The 3T lost GPS 15.46 km from Kalyan at 21.9 m/s. That seeded a 706 s
    /// countdown which then ran, unchecked, for 643 s of blackout and started
    /// the ladder near Diva: 10.5 km and 12.6 minutes short of the stop. The
    /// rider woke, acked, and the ack ADVANCED THE CURSOR, so Kalyan was
    /// resolved and the real alarm could never fire. He reached Kalyan in
    /// silence.
    ///
    /// The journey here is the file's Kalyan -> Digha chain, and the seeding
    /// fix sits on Kalyan itself: 15.57 km from Digha, within 120 m of the
    /// real ride's geometry, giving a 711 s seed against the ride's 706 s.
    group('the coast is bounded, because a stale projection SPENDS the '
        'alarm', () {
      WakeEscalation newWake() => WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      void seedFarFix(WakeEscalation wake) => wake.onFix(
        lat: 19.2358216,
        lng: 73.1308101,
        accuracyM: 20,
        speedMps: 21.9,
        now: _t0,
      );

      test('a countdown seeded 711 s out NEVER fires the ladder, however '
          'long the blackout runs', () {
        final wake = newWake();
        seedFarFix(wake);

        // 643 s: the exact coast the 3T ran. The old code computed
        // 711 - 643 = 68 s remaining, crossed the 90 s window, and woke him.
        // The tick is not empty (this is the first one past the bound, so it
        // carries the note), but it makes NO SOUND, which is the claim.
        final coasted = wake.onTick(_t0.add(const Duration(seconds: 643)));
        expect(coasted.whereType<Speak>(), isEmpty);
        expect(coasted.whereType<Tone>(), isEmpty);
        expect(wake.isLadderLive, isFalse);

        // And it stays dead however long the fixes stay away. The ladder is
        // not lost, it is WAITING: a station event still arms it, which is
        // what actually happened at Thakurli on the iPhone the same ride.
        expect(wake.onTick(_t0.add(const Duration(minutes: 30))), isEmpty);
        expect(wake.isLadderLive, isFalse);

        final armed = wake.onStationEvent(
          _arrival('thane'),
          _t0.add(const Duration(minutes: 30)),
        );
        expect(armed.whereType<Speak>(), hasLength(1));
        expect(wake.isLadderLive, isTrue);
      });

      test('abandoning the projection says so in the log, ONCE, not once a '
          'tick', () {
        final wake = newWake();
        seedFarFix(wake);

        // Inside the bound: nothing to say yet.
        expect(wake.onTick(_t0.add(const Duration(seconds: 180))), isEmpty);

        final crossing = wake.onTick(_t0.add(const Duration(seconds: 181)));
        expect(crossing, hasLength(1));
        expect(crossing.single, isA<WakeNote>());
        expect(
          (crossing.single as WakeNote).message,
          contains('dead reckoning abandoned'),
        );

        // Every later tick of the same blackout is silent. This engine ticks
        // for as long as the fixes stay away, and a line per tick would bury
        // the ride log the note exists to explain.
        for (var s = 182; s < 200; s++) {
          expect(wake.onTick(_t0.add(Duration(seconds: s))), isEmpty);
        }
      });

      test('a second blackout is reported again: the note follows the '
          'FIXES, not the ride', () {
        final wake = newWake();
        seedFarFix(wake);
        expect(
          wake.onTick(_t0.add(const Duration(seconds: 181))).single,
          isA<WakeNote>(),
        );

        // GPS comes back far from the target, then dies again.
        wake.onFix(
          lat: 19.2358216,
          lng: 73.1308101,
          accuracyM: 20,
          speedMps: 21.9,
          now: _t0.add(const Duration(seconds: 300)),
        );
        expect(wake.onTick(_t0.add(const Duration(seconds: 480))), isEmpty);
        expect(
          wake.onTick(_t0.add(const Duration(seconds: 481))).single,
          isA<WakeNote>(),
        );
      });

      test('THE BOUND CAN STILL FAIL TO WITHHOLD: a blackout in the final '
          'approach fires exactly as before', () {
        // The pair that proves the bound is a bound and not an off switch.
        // Mumbra is 3188 m from Digha. At 12 m/s that is a 266 s seed, which
        // crosses the 90 s lead window at 176 s of staleness, INSIDE the
        // 180 s coast. This is what dead reckoning is for.
        final wake = newWake();
        wake.onFix(
          lat: 19.18979,
          lng: 73.02325,
          accuracyM: 20,
          speedMps: 12,
          now: _t0,
        );

        expect(wake.onTick(_t0.add(const Duration(seconds: 175))), isEmpty);
        final fired = wake.onTick(_t0.add(const Duration(seconds: 176)));
        expect(fired.whereType<Speak>(), hasLength(1));
        expect(wake.isLadderLive, isTrue);
      });

      test('and the same approach at 11.5 m/s is withheld, because the '
          'crossing falls 7 s past the bound', () {
        // The other half of the pair. Identical position, 0.5 m/s slower: a
        // 277 s seed crossing at 187 s of staleness, just outside the coast.
        // Nothing about this test differs except the number the bound tests.
        final wake = newWake();
        wake.onFix(
          lat: 19.18979,
          lng: 73.02325,
          accuracyM: 20,
          speedMps: 11.5,
          now: _t0,
        );

        expect(wake.onTick(_t0.add(const Duration(seconds: 180))), isEmpty);
        expect(
          wake.onTick(_t0.add(const Duration(seconds: 181))).single,
          isA<WakeNote>(),
        );
        expect(wake.onTick(_t0.add(const Duration(seconds: 188))), isEmpty);
        expect(wake.isLadderLive, isFalse);
      });
    });
  });

  group('calls suspend the wake clock', () {
    test(
      'a call starting mid-ladder stops the tone and freezes escalation',
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
      },
    );

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
      final rung1 = wake.onTick(hangUp.add(const Duration(seconds: 25)));
      expect((rung1[0] as Tone).volume, 0.3);
    });

    test('a suspension that never gets an ended event resumes itself at the '
        'timeout (the 18 Jul iPhone ladder death)', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1

      // The real 18 Jul event: the Music app seized the session (the
      // rider's own double-tap gone astray), the begin event suspended the
      // ladder, and no ended event ever came because iOS does not
      // guarantee one. The ladder stayed dead for the rest of the ride.
      final suspendAt = _t0.add(const Duration(seconds: 30));
      wake.onCallStateChanged(inCall: true, now: suspendAt);

      // Still frozen inside the timeout window.
      expect(wake.onTick(suspendAt.add(const Duration(minutes: 2))), isEmpty);

      // At the timeout the engine assumes the ended event was lost and
      // resumes on its own: the check-in comes back and silence escalates
      // again. A false resume during a real long call costs an awake
      // rider one ack tap; a ladder that never comes back costs a
      // sleeping rider their stop.
      final resume = wake.onTick(suspendAt.add(const Duration(minutes: 3)));
      expect(resume, hasLength(1));
      expect(
        (resume.single as Speak).text,
        'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );
      final rung1 = wake.onTick(
        suspendAt.add(const Duration(minutes: 3, seconds: 25)),
      );
      expect((rung1[0] as Tone).volume, 0.3);
    });

    test('the stop passing during an unresumed suspension comes back firm '
        'at the timeout', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onCallStateChanged(inCall: true, now: _t0);
      wake.onStationEvent(
        _arrival('thane'),
        _t0.add(const Duration(minutes: 1)),
      );
      wake.onStationEvent(
        _arrival('digha'),
        _t0.add(const Duration(minutes: 2)),
      );

      final resume = wake.onTick(_t0.add(const Duration(minutes: 3)));
      expect(resume, hasLength(3));
      expect((resume[0] as Tone).volume, 1.0);
      expect(resume[1], isA<Vibrate>());
      expect(
        (resume[2] as Speak).text,
        'While you were on your call, the train reached your stop, '
        'Digha Gaon. Get off the train now.',
      );
    });

    test('a real ended event before the timeout clears the deadline', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('thane'), _t0);
      wake.onCallStateChanged(
        inCall: true,
        now: _t0.add(const Duration(seconds: 5)),
      );
      wake.onCallStateChanged(
        inCall: false,
        now: _t0.add(const Duration(minutes: 1)),
      );
      wake.acknowledge(_t0.add(const Duration(minutes: 1, seconds: 5)));

      // The old deadline must not fire a phantom resume after the ladder
      // was legitimately resumed and acknowledged.
      expect(wake.onTick(_t0.add(const Duration(minutes: 4))), isEmpty);
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
      final rung = wake.onTick(
        _t0.add(const Duration(minutes: 2, seconds: 30)),
      );
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

    test('a walk interchange does not ceiling on its own other half', () {
      // Churchgate -> Kalyan: alight Dadar Western, cross the bridge, board
      // Dadar Central. The planner puts BOTH halves on the chain, and the two
      // centres are 207 m apart behind 450 m fences, so the rider is inside
      // the Central fence while still standing on the Western platform.
      // Ceilinging there would kill the alarm at the moment the rider still
      // has a train to get off and a bridge to cross.
      final wake = WakeEscalation(
        chain: _dadarChain,
        interchangeStationIds: const ['dadar_western'],
        destinationStationId: 'sion',
        walkInterchangeStationIds: const {'dadar_western'},
      );

      // Armed by the interchange's own 1200 m approach fence, not by the
      // arrival at Prabhadevi. Prabhadevi is the ORIGIN of this fixture, and
      // arming a ladder there is the 13 Aug one-station bug: the origin is
      // announced on the ride's first fix, so this used to start the alarm
      // the instant the rider pressed Start. The ceiling behaviour under
      // test is unchanged either way.
      wake.onStationEvent(
        Announcement(
          stationId: 'dadar_western',
          kind: AnnouncementKind.approach,
          text: 'Now approaching Dadar.',
        ),
        _t0,
      );
      wake.onTick(_t0.add(const Duration(seconds: 25))); // rung 1
      expect(wake.isLadderLive, isTrue);

      // The other half of the same complex. NOT a station past the rider.
      final atPartner = wake.onStationEvent(
        _arrival('dadar'),
        _t0.add(const Duration(seconds: 40)),
      );
      expect(atPartner, isEmpty);
      expect(
        wake.isLadderLive,
        isTrue,
        reason: 'the alarm must survive arrival at the walk partner',
      );

      // Matunga is the first station that genuinely means "gone too far".
      final past = wake.onStationEvent(
        _arrival('matunga'),
        _t0.add(const Duration(minutes: 3)),
      );
      expect(past, hasLength(2));
      expect(past[0], isA<StopTone>());
      expect(past[1], isA<HardStop>());
    });

    test('an ordinary interchange still ceilings at the very next station', () {
      // The same chain without the walk declaration: proves the skip is driven
      // by walkInterchangeStationIds and is not a blanket loosening.
      final wake = WakeEscalation(
        chain: _dadarChain,
        interchangeStationIds: const ['dadar_western'],
        destinationStationId: 'sion',
      );

      // Armed by the interchange's own approach fence, as above.
      wake.onStationEvent(
        Announcement(
          stationId: 'dadar_western',
          kind: AnnouncementKind.approach,
          text: 'Now approaching Dadar.',
        ),
        _t0,
      );
      wake.onTick(_t0.add(const Duration(seconds: 25)));

      final atNext = wake.onStationEvent(
        _arrival('dadar'),
        _t0.add(const Duration(seconds: 40)),
      );
      expect(atNext, hasLength(2));
      expect(atNext[1], isA<HardStop>());
    });
  });

  group('ladder trigger by previous-station detection', () {
    test(
      'announcing the station before the destination starts the check-in',
      () {
        final wake = WakeEscalation(
          chain: _chain,
          interchangeStationIds: const [],
          destinationStationId: 'digha',
        );

        expect(wake.isLadderLive, isFalse);
        final actions = wake.onStationEvent(_arrival('thane'), _t0);

        expect(actions, hasLength(1));
        final speak = actions.single;
        expect(speak, isA<Speak>());
        expect(
          (speak as Speak).text,
          'Your stop, Digha Gaon, is next. Tap your earphones, or press the '
          'I am awake button, to show you are awake.',
        );
        expect(wake.isLadderLive, isTrue);
      },
    );
  });

  group('A LADDER BEHIND THE TRAIN MUST NOT HOLD THE ONES AHEAD', () {
    // THE 28 AUG 2026 RIDE. The OS killed the app between Prabhadevi and
    // Mahalaxmi, eight minutes after the rider had already changed trains at
    // Dadar. He reopened it and tapped resume, the ride rebuilt itself from the
    // journey with the cursor at zero, and it spent the rest of the trip
    // waiting for a Dadar change that was already behind the train. CHURCHGATE
    // NEVER RANG. The 3T in the same pocket, never killed, woke him at Marine
    // Lines. The announcements were perfect on both phones. Only the alarm was
    // dead, which is the one failure this app cannot have.

    test('a ride joined past an interchange still wakes at the stop', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // The train is already at Digha's doorstep, well past Thane, which is
      // what a resumed ride looks like to a freshly built engine.
      final notes = wake.localize(8);
      expect(notes.single, isA<WakeNote>());

      // Digha is the destination and Airoli is past it, so the trigger is the
      // station before: Thane. Without the skip this does nothing at all.
      final actions = wake.onStationEvent(_arrival('thane'), _t0);

      expect(actions, hasLength(1));
      expect(
        (actions.single as Speak).text,
        startsWith('Your stop, Digha Gaon, is next.'),
      );
    });

    test('and without the skip it is silent, which is the bug', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // No localize call: the cursor sits on Thane forever.
      expect(wake.onStationEvent(_arrival('thane'), _t0), isEmpty);
    });

    test('a train short of the interchange keeps its interchange ladder', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // At Kalwa, one before Thane. Nothing is behind the train yet.
      expect(wake.localize(6), isEmpty);

      final actions = wake.onStationEvent(_arrival('kalwa'), _t0);
      expect(
        (actions.single as Speak).text,
        startsWith('Your train change at Thane is next.'),
      );
    });

    test('a WALK interchange is not skipped from its own near platform', () {
      // The rider standing on Dadar Western is already inside Dadar Central's
      // fence, 207 m away. Skipping there would drop the alarm at the exact
      // moment they still have a bridge to cross, which is why the skip uses
      // the same ceiling the hard stop does.
      final wake = WakeEscalation(
        chain: _dadarChain,
        interchangeStationIds: const ['dadar_western'],
        destinationStationId: 'sion',
        walkInterchangeStationIds: const {'dadar_western'},
      );

      // reachedIndex 2 is Dadar Central, the far half of the pair.
      expect(wake.localize(2), isEmpty, reason: 'the walk is not over');

      // Matunga, past the whole pair, is where it may finally go.
      expect(wake.localize(3), hasLength(1));
    });

    test('a live ladder is left to the ceiling, not silently skipped', () {
      // Standing a live ladder down here would drop the tone without a
      // StopTone, leaving the alarm sounding with nothing to answer it.
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );
      wake.onStationEvent(_arrival('kalwa'), _t0);
      expect(wake.isLadderLive, isTrue);

      expect(wake.localize(9), isEmpty);
      expect(wake.isLadderLive, isTrue, reason: 'the ceiling ends this one');
    });

    test('the destination itself is never skipped', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      // Every index there is, including past the end of the chain.
      for (var i = 0; i <= _chain.length; i++) {
        wake.localize(i);
      }

      final actions = wake.onStationEvent(_arrival('thane'), _t0);
      expect(
        (actions.single as Speak).text,
        startsWith('Your stop, Digha Gaon, is next.'),
      );
    });
  });

  group('THE STOP OUTRANKS THE PLAN, docs/adr/0004', () {
    // The other half of the same hole, and the one the Ghansoli tester found: a
    // rider whose plan carries a change and who takes a different line never
    // resolves that ladder, and the chain gives localize nothing to read
    // because she has left it. Being near her stop has to be enough on its own.

    test('nearing the stop arms it even with a change unresolved', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // 800 m short of Digha at 20 m/s, and nowhere near Thane. The cursor is
      // still on Thane and no station event will ever move it.
      final actions = wake.onFix(
        lat: 19.1837,
        lng: 72.9944301,
        accuracyM: 20,
        speedMps: 20,
        now: _t0,
      );

      expect(actions.first, isA<WakeNote>());
      expect(
        (actions.last as Speak).text,
        startsWith('Your stop, Digha Gaon, is next.'),
      );
    });

    test('a change that is merely still ahead is not abandoned', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const ['thane'],
        destinationStationId: 'digha',
      );

      // Right at Thane, which is 2.1 km from Digha. At 30 m/s the DESTINATION
      // is inside the 90 s lead time, so the override could fire here. It must
      // not: the change is closer, the rider has not left the plan, and the
      // ladder that arms is the one for the change.
      final actions = wake.onFix(
        lat: 19.1864830,
        lng: 72.9757664,
        accuracyM: 20,
        speedMps: 30,
        now: _t0,
      );

      expect(actions.whereType<WakeNote>(), isEmpty);
      expect(
        (actions.single as Speak).text,
        startsWith('Your train change at Thane is next.'),
      );
    });
  });
}

/// The rider's own wake toggle, 12 Aug 2026. It suspends through the SAME door
/// as a call because it wants the same behaviour, and differs in exactly one
/// way: no catch-up on the way back.
void _wakeToggleTests() {
  group("THE RIDER'S WAKE TOGGLE", () {
    WakeEscalation build() => WakeEscalation(
      chain: _chain,
      interchangeStationIds: const [],
      destinationStationId: 'digha',
    );

    test('re-arming says NOTHING about what went by', () {
      final wake = build();

      // Alarm off, and the train passes the trigger station while it is off.
      wake.onCallStateChanged(inCall: true, now: _t0);
      expect(wake.onStationEvent(_arrival('kalwa'), _t0), isEmpty);
      expect(
        wake.onStationEvent(
          _arrival('thane'),
          _t0.add(const Duration(minutes: 2)),
        ),
        isEmpty,
      );

      final back = _t0.add(const Duration(minutes: 3));
      final resumed = wake.onCallStateChanged(
        inCall: false,
        now: back,
        catchUp: false,
      );

      // The same sequence with catchUp true speaks "While you were on your
      // call, the train passed Kalwa and Thane." The rider was not on a call,
      // and the app does not owe a report for a decision they made.
      expect(
        resumed.whereType<Speak>().map((s) => s.text),
        isEmpty,
        reason: 'a rider who switched their own alarm off gets no catch-up',
      );
    });

    test('AND IT ARMS FOR WHAT IS AHEAD, from the next fix', () {
      // Re-arming invents nothing at the moment it happens, which is the whole
      // point of no catch-up: the ladder is not live the instant the rider
      // presses it, even though the trigger station went by while it was off.
      // What covers them is the ETA zone, on the very next fix, exactly as it
      // covers a rider whose fences were jumped.
      final wake = build();
      wake.onCallStateChanged(inCall: true, now: _t0);
      wake.onStationEvent(
        _arrival('thane'),
        _t0.add(const Duration(minutes: 2)),
      );

      final back = _t0.add(const Duration(minutes: 3));
      wake.onCallStateChanged(inCall: false, now: back, catchUp: false);
      expect(
        wake.isLadderLive,
        isFalse,
        reason: 're-arming must not invent a ladder out of nothing',
      );

      // Between Thane and Digha at 15 m/s: about 1.0 km, 69 s out, inside the
      // 90 s lead window.
      final near = wake.onFix(
        lat: 19.1836,
        lng: 72.9851,
        accuracyM: 20,
        speedMps: 15,
        now: back.add(const Duration(seconds: 5)),
      );

      expect(near, isNotEmpty, reason: 'the rest of the journey is covered');
      expect(wake.isLadderLive, isTrue);
    });

    test('a call still gets its catch-up, unchanged', () {
      // The default is what it always was, so this change cannot have moved
      // the call behaviour the 13 Jul return leg is the reason for.
      final wake = build();
      wake.onCallStateChanged(inCall: true, now: _t0);
      wake.onStationEvent(_arrival('kalwa'), _t0);
      wake.onStationEvent(
        _arrival('thane'),
        _t0.add(const Duration(minutes: 2)),
      );

      final spoken = wake
          .onCallStateChanged(
            inCall: false,
            now: _t0.add(const Duration(minutes: 3)),
          )
          .whereType<Speak>();

      expect(spoken, hasLength(1));
      expect(spoken.single.text, startsWith('While you were on your call'));
    });
  });

  _oneStationJourneyTests();
}

/// Shahad to Ambivli: adjacent stations, so the chain is two long and the
/// station "one before the target" IS the origin.
///
/// Reported by the owner on 13 Aug 2026 from the moto edge 50 neo, at the desk,
/// without riding anything. The screen also promised "2 stations before
/// Ambivli" on a route that contains no such station.
void _oneStationJourneyTests() {
  final shortChain = <Station>[
    _s('shahad', 'Shahad', 19.2519, 73.1300, 400),
    _s('ambivli', 'Ambivli', 19.2686, 73.1531, 400),
  ];

  Announcement approach(String stationId) => Announcement(
    stationId: stationId,
    kind: AnnouncementKind.approach,
    text: 'Now approaching $stationId.',
  );

  WakeEscalation build() => WakeEscalation(
    chain: shortChain,
    interchangeStationIds: const [],
    destinationStationId: 'ambivli',
  );

  group('a journey one station long', () {
    test('THE ORIGIN DOES NOT START THE LADDER. RideProgress announces it on '
        'the ride\'s first fix, so this fired the alarm at the moment the '
        'rider pressed Start', () {
      final wake = build();

      final actions = wake.onStationEvent(_arrival('shahad'), _t0);

      expect(actions, isEmpty);
      expect(wake.isLadderLive, isFalse);
    });

    test('nothing the origin can say arms it: a passed counts no more than an '
        'arrival', () {
      final wake = build();

      final passed = wake.onStationEvent(
        Announcement(
          stationId: 'shahad',
          kind: AnnouncementKind.passed,
          text: 'You have passed Shahad.',
        ),
        _t0,
      );

      expect(passed, isEmpty);
      expect(wake.isLadderLive, isFalse);
    });

    test('THE DESTINATION\'S OWN APPROACH FENCE ARMS IT INSTEAD, so the rider '
        'is still woken', () {
      final wake = build();
      wake.onStationEvent(_arrival('shahad'), _t0);

      final armed = wake.onStationEvent(
        approach('ambivli'),
        _t0.add(const Duration(minutes: 2)),
      );

      expect(wake.isLadderLive, isTrue);
      expect(armed, hasLength(1));
      expect(
        (armed.single as Speak).text,
        'Your stop, Ambivli, is next. Tap your earphones, or press the '
        'I am awake button, to show you are awake.',
      );
    });

    test('and it still climbs from there, so this is a real ladder and not '
        'one announcement', () {
      final wake = build();
      wake.onStationEvent(approach('ambivli'), _t0);

      final rung1 = wake.onTick(_t0.add(const Duration(seconds: 25)));

      expect(rung1, hasLength(2));
      expect(rung1[0], isA<Tone>());
      expect(
        (rung1[1] as Speak).text,
        'Wake up! Wake up. Your stop, Ambivli, is next.',
      );
    });

    test('an acknowledgement still stands it down', () {
      final wake = build();
      wake.onStationEvent(approach('ambivli'), _t0);
      expect(wake.isLadderLive, isTrue);

      wake.acknowledge(_t0.add(const Duration(seconds: 5)));

      expect(wake.isLadderLive, isFalse);
      expect(wake.onTick(_t0.add(const Duration(seconds: 30))), isEmpty);
    });

    test('a call still suppresses it: the approach must not start a ladder '
        'into the rider\'s conversation', () {
      final wake = build();
      wake.onCallStateChanged(inCall: true, now: _t0);

      final armed = wake.onStationEvent(
        approach('ambivli'),
        _t0.add(const Duration(seconds: 10)),
      );

      expect(armed, isEmpty);
      expect(wake.isLadderLive, isFalse);
    });

    test('the approach arms it once, not on every repeat', () {
      final wake = build();
      wake.onStationEvent(approach('ambivli'), _t0);
      final second = wake.onStationEvent(
        approach('ambivli'),
        _t0.add(const Duration(seconds: 5)),
      );

      expect(second, isEmpty);
    });
  });

  group('a longer journey is untouched by the one-station fix', () {
    test('the station before the target still arms the ladder', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      final armed = wake.onStationEvent(_arrival('thane'), _t0);

      expect(wake.isLadderLive, isTrue);
      expect(armed, hasLength(1));
    });

    test('AND THE ORIGIN STILL CANNOT ARM IT, which is the same rule seen '
        'from the other end', () {
      final wake = WakeEscalation(
        chain: _chain,
        interchangeStationIds: const [],
        destinationStationId: 'digha',
      );

      expect(wake.onStationEvent(_arrival('kalyan'), _t0), isEmpty);
      expect(wake.isLadderLive, isFalse);
    });
  });
}
