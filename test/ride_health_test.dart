import 'package:commute_guardian/services/ride_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// GPS_LOST and STALL, two of the handover's edge states (section 4.1).
///
/// Both are notices. Nothing in this engine can move the chain, arm the wake
/// ladder or end a ride, and the tests are mostly about it staying QUIET: an
/// edge state that fires on an ordinary Mumbai local is worse than one that
/// never fires, because the rider learns to ignore the voice they installed the
/// app to be woken by.
void main() {
  final t0 = DateTime(2026, 8, 5, 18, 30);

  /// Feeds usable fixes every 10 s up to [until], so the engine sees a healthy
  /// stream the way the service's own sampling gives it one.
  void fixesUntil(
    RideHealth health,
    Duration until, {
    Duration from = Duration.zero,
  }) {
    for (var s = from.inSeconds; s <= until.inSeconds; s += 10) {
      health.onFix(t0.add(Duration(seconds: s)), usable: true);
    }
  }

  List<String> spoken(List<RideHealthAction> actions) => [
    for (final a in actions)
      if (a is RideHealthSpeak) a.text,
  ];

  group('GPS_LOST', () {
    test('a healthy stream is never remarked on', () {
      final health = RideHealth();
      fixesUntil(health, const Duration(minutes: 30));
      expect(health.onTick(t0.add(const Duration(minutes: 30))), isEmpty);
    });

    test('a wobble under two minutes says nothing', () {
      // Every cutting between Kalwa and Mumbra would otherwise narrate itself.
      final health = RideHealth();
      fixesUntil(health, const Duration(minutes: 1));
      expect(
        health.onTick(t0.add(const Duration(minutes: 2, seconds: 50))),
        isEmpty,
      );
    });

    test('two minutes of silence is said once, and it is actionable', () {
      final health = RideHealth();
      fixesUntil(health, const Duration(minutes: 1));

      final warned = health.onTick(
        t0.add(const Duration(minutes: 3, seconds: 1)),
      );
      expect(spoken(warned), hasLength(1));
      // It promises that the ride is still on, which is the doubt a rider
      // actually has, and tells them the one thing they can do about it. It
      // does NOT promise to keep counting stations, because it cannot.
      expect(spoken(warned).single, contains('Travel Mode is still on'));
      expect(spoken(warned).single, contains('door or a window'));

      // Ticks are seconds apart. Once is a warning, twice a minute is a fault.
      expect(
        health.onTick(t0.add(const Duration(minutes: 3, seconds: 6))),
        isEmpty,
      );
    });

    test('A RIDE THROUGH PATCHY COVER DOES NOT NARRATE ITS SIGNAL', () {
      // The failure mode of this whole feature. Warn on every gap and the rider
      // stops listening to the voice that is supposed to wake them.
      final health = RideHealth();
      fixesUntil(health, const Duration(minutes: 1));
      health.onTick(t0.add(const Duration(minutes: 3, seconds: 1)));

      // Signal back, then lost again a few minutes later.
      fixesUntil(
        health,
        const Duration(minutes: 6),
        from: const Duration(minutes: 4),
      );
      final second = health.onTick(
        t0.add(const Duration(minutes: 8, seconds: 1)),
      );
      expect(spoken(second), isEmpty);
      expect(second.whereType<RideHealthNote>(), hasLength(1));
    });

    test('past the quiet window it may warn again', () {
      // A gap twenty minutes later is a new event, not the same one.
      final health = RideHealth();
      fixesUntil(health, const Duration(minutes: 1));
      health.onTick(t0.add(const Duration(minutes: 3, seconds: 1)));

      fixesUntil(
        health,
        const Duration(minutes: 25),
        from: const Duration(minutes: 4),
      );
      expect(
        spoken(health.onTick(t0.add(const Duration(minutes: 27, seconds: 1)))),
        hasLength(1),
      );
    });

    test('an unusable fix is not evidence the stream is healthy', () {
      // Same definition of usable the chain projection applies: a fix the OS is
      // unsure of localises nothing, so it cannot prove the stream is alive.
      final health = RideHealth();
      health.onFix(t0, usable: true);
      for (var s = 10; s <= 200; s += 10) {
        health.onFix(t0.add(Duration(seconds: s)), usable: false);
      }
      expect(
        spoken(health.onTick(t0.add(const Duration(seconds: 200)))),
        hasLength(1),
      );
    });
  });

  group('STALL', () {
    /// A ride with [count] segments of [each], starting after the first fix.
    RideHealth riding({
      int count = 3,
      Duration each = const Duration(minutes: 4),
    }) {
      final health = RideHealth();
      health.onFix(t0, usable: true);
      var at = t0;
      for (var i = 0; i < count; i++) {
        at = at.add(each);
        fixesUntil(
          health,
          Duration(seconds: at.difference(t0).inSeconds),
          from: Duration(seconds: at.difference(t0).inSeconds - each.inSeconds),
        );
        health.onStationPassed(at);
      }
      return health;
    }

    test('nothing is said before the ride has segments to compare', () {
      // Two stations in, "three times the median" is arithmetic on one number.
      final health = riding(count: 1);
      health.onFix(t0.add(const Duration(minutes: 40)), usable: true);
      expect(health.onTick(t0.add(const Duration(minutes: 40))), isEmpty);
    });

    test('an ordinary long gap is not a stall', () {
      // Four minute segments, and the train takes eleven to the next one. That
      // is a Mumbai local, not a failure.
      final health = riding();
      fixesUntil(
        health,
        const Duration(minutes: 23),
        from: const Duration(minutes: 12),
      );
      expect(health.onTick(t0.add(const Duration(minutes: 23))), isEmpty);
    });

    test('three times the ride\'s own median, said once, gently', () {
      final health = riding();
      fixesUntil(
        health,
        const Duration(minutes: 25),
        from: const Duration(minutes: 12),
      );

      final held = health.onTick(t0.add(const Duration(minutes: 25)));
      expect(spoken(held), hasLength(1));
      expect(spoken(held).single, contains('held up'));
      // It says nothing about WHY. The app cannot tell a signal failure at Diva
      // from a chain snatching at Mumbra, and a guess is the thing a rider
      // quotes back at it.
      expect(spoken(held).single, contains('still watching for your stop'));

      expect(health.onTick(t0.add(const Duration(minutes: 26))), isEmpty);
    });

    test('THE FLOOR OUTRANKS THE MEDIAN', () {
      // A Harbour line ride with 90 second hops: three times the median is four
      // and a half minutes, which is an ordinary wait at a signal. The floor is
      // what stops this engine crying wolf on the shortest segments in the
      // network.
      final health = riding(count: 3, each: const Duration(minutes: 90 ~/ 60));
      fixesUntil(
        health,
        const Duration(minutes: 10),
        from: const Duration(minutes: 3),
      );
      expect(health.onTick(t0.add(const Duration(minutes: 10))), isEmpty);
    });

    test('moving again clears it, and it can fire once more later', () {
      final health = riding();
      fixesUntil(
        health,
        const Duration(minutes: 25),
        from: const Duration(minutes: 12),
      );
      health.onTick(t0.add(const Duration(minutes: 25)));

      final moving = health.onStationPassed(
        t0.add(const Duration(minutes: 26)),
      );
      expect(moving.whereType<RideHealthNote>(), hasLength(1));

      fixesUntil(
        health,
        const Duration(minutes: 50),
        from: const Duration(minutes: 26),
      );
      expect(
        spoken(health.onTick(t0.add(const Duration(minutes: 50)))),
        hasLength(1),
      );
    });

    test('AN INTERCHANGE IS NOT A STALL (18 Jul, Thane)', () {
      // FOUND BY REPLAYING THE SIX REAL LOGS through this engine, not by
      // thinking about it. On 18 Jul the gap between arriving at Thane and
      // reaching Digha Gaon was eighteen minutes, and it fired. That gap is the
      // interchange the app itself announced: get off, walk to platform 9,
      // wait, board a Trans Harbour train. The journey knows where every change
      // is, so the engine is told rather than left to guess.
      final health = riding();
      health.onStationPassed(
        t0.add(const Duration(minutes: 12)),
        changeHere: true,
      );
      fixesUntil(
        health,
        const Duration(minutes: 30),
        from: const Duration(minutes: 12),
      );

      expect(health.onTick(t0.add(const Duration(minutes: 30))), isEmpty);

      // And the clock restarts on the next train, rather than staying off.
      health.onStationPassed(t0.add(const Duration(minutes: 31)));
      fixesUntil(
        health,
        const Duration(minutes: 55),
        from: const Duration(minutes: 31),
      );
      expect(
        spoken(health.onTick(t0.add(const Duration(minutes: 55)))),
        hasLength(1),
      );
    });

    test('AFTER THE DESTINATION THERE IS NO TRAIN TO BE HELD UP (22 Jul)', () {
      // The same replay fired at 16:02 on 22 Jul, sixteen minutes after the
      // Shahad overshoot, while the owner was walking home with the ride still
      // running. After the destination or an overshoot pin there are no more
      // stations to cross by design, so every further minute looks like a
      // stall and none of them is one.
      final health = riding();
      health.onStationPassed(
        t0.add(const Duration(minutes: 12)),
        endsWatch: true,
      );
      fixesUntil(
        health,
        const Duration(minutes: 60),
        from: const Duration(minutes: 12),
      );

      expect(health.onTick(t0.add(const Duration(minutes: 60))), isEmpty);
    });

    test('a silent GPS is reported as a signal problem, not as a stall', () {
      // Without fixes the train may have passed three stations unheard, so a
      // stall cannot be diagnosed at all. Two warnings about one silence is one
      // too many, and the signal one is the true one.
      final health = riding();
      final actions = health.onTick(t0.add(const Duration(minutes: 40)));
      expect(spoken(actions), hasLength(1));
      expect(spoken(actions).single, contains('signal is weak'));
    });
  });
}
