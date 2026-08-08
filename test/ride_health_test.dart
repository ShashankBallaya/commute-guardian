import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// GPS_LOST, STALL and WRONG_DIRECTION, the handover's edge states (section
/// 4.1) that are notices.
///
/// All three are notices. Nothing in this engine can move the chain, arm the wake
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

  group('WRONG_DIRECTION', () {
    // Real coords from assets/stations/mumbai_suburban.json. A rider boarding
    // at Dadar for Kalyan who takes the wrong platform arrives at Parel: one
    // stop the other way, and a station this ride was never going to pass.
    final dadar = _s('dadar', 'Dadar', 19.0173761, 72.8430265, 450);
    final parel = _s('parel', 'Parel', 19.0094817, 72.8376614, 350);
    final currey = _s(
      'currey_road',
      'Currey Road',
      18.9937486,
      72.8328556,
      300,
    );

    RideHealth boardingAtDadar() => RideHealth(
      origin: dadar,
      destinationName: 'Kalyan',
      wrongWayStations: [parel],
    );

    /// Arms the watch the way a real ride does: a usable fix on the platform.
    void arrive(RideHealth health, Station at, {Duration at_ = Duration.zero}) {
      health.onFix(t0.add(at_), usable: true, lat: at.lat, lng: at.lng);
    }

    test('standing on the right platform is never remarked on', () {
      final health = boardingAtDadar();
      for (var s = 0; s <= 300; s += 10) {
        expect(
          spoken(
            health.onFix(
              t0.add(Duration(seconds: s)),
              usable: true,
              lat: dadar.lat,
              lng: dadar.lng,
            ),
          ),
          isEmpty,
        );
      }
    });

    test('one stop the wrong way is said once, and it names the destination', () {
      final health = boardingAtDadar();
      arrive(health, dadar);

      final warned = spoken(
        health.onFix(
          t0.add(const Duration(minutes: 4)),
          usable: true,
          lat: parel.lat,
          lng: parel.lng,
        ),
      );
      expect(warned, hasLength(1));
      expect(warned.single, contains('heading away from Kalyan'));
      // It tells the rider the one thing they can do, and promises the ride is
      // still running rather than asking a question nothing can answer: the app
      // has no notification buttons (30 Jul swipe bench).
      expect(warned.single, contains('cross to the other platform'));
      expect(warned.single, contains('Travel Mode is still on'));
      expect(warned.single, isNot(contains('?')));

      // Riding further the wrong way does not say it again.
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 6)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        isEmpty,
      );
    });

    test('A RIDE THAT STARTS AWAY FROM ITS ORIGIN MAKES NO CLAIM', () {
      // The arming rule, and the reason it exists: a rider planning Dadar to
      // Kalyan while still riding INTO Dadar is sitting at Matunga at the
      // instant the ride starts. Unarmed, that is a wrong-way pin and the app
      // would warn them off a train they have not boarded.
      final health = boardingAtDadar();
      expect(
        spoken(health.onFix(t0, usable: true, lat: parel.lat, lng: parel.lng)),
        isEmpty,
      );

      // Reaching Dadar arms it, and the same pin now counts.
      arrive(health, dadar, at_: const Duration(minutes: 2));
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 8)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        hasLength(1),
      );
    });

    test('the right train closes the watch for good', () {
      // One chain station past the origin is proof of direction: the chain only
      // holds stations between origin and destination, so reaching one cannot
      // happen on a wrong-platform train. After that the rider may go anywhere,
      // including back through a pin at the end of the day, in silence.
      final health = boardingAtDadar();
      arrive(health, dadar);
      health.onStationPassed(
        t0.add(const Duration(minutes: 3)),
        stationId: 'sion',
      );

      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 40)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        isEmpty,
      );
    });

    test('THE ORIGIN ITSELF DOES NOT CLOSE THE WATCH', () {
      // RideProgress announces the origin on the ride's very first fix, so a
      // rule of "any station passed proves direction" would disarm the watch
      // before it had ever looked. This is the whole ride's worth of the bug.
      final health = boardingAtDadar();
      arrive(health, dadar);
      health.onStationPassed(t0, stationId: 'dadar');

      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 5)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        hasLength(1),
      );
    });

    test('an unusable fix cannot claim the rider is anywhere', () {
      // Same definition of usable as everywhere else. An accuracy blackout on
      // top of a wrong-way pin is not evidence of a wrong train.
      final health = boardingAtDadar();
      arrive(health, dadar);
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 4)),
            usable: false,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        isEmpty,
      );
    });

    test('a ride with nothing behind its origin stays quiet forever', () {
      // CSMT and Churchgate: every train leaves the same way, so there is no
      // wrong direction to catch and no pins to catch it with.
      final health = RideHealth(
        origin: dadar,
        destinationName: 'Kalyan',
        wrongWayStations: const [],
      );
      arrive(health, dadar);
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 4)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        isEmpty,
      );
    });

    test('a fix near a pin but outside its fence says nothing', () {
      // Proximity is the whole test, so the fence radius is the whole margin.
      // Currey Road sits at 300 m for a reason (Chinchpokli is a few hundred
      // metres away) and a warning that fired between stations would fire on
      // every ride through the densest stretch of the network.
      final health = RideHealth(
        origin: dadar,
        destinationName: 'Kalyan',
        wrongWayStations: [currey],
      );
      arrive(health, dadar);
      // ~400 m north of Currey Road, outside its 300 m fence.
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 4)),
            usable: true,
            lat: currey.lat + 0.0036,
            lng: currey.lng,
          ),
        ),
        isEmpty,
      );
    });

    test('a fix with no coordinates feeds the clocks and claims nothing', () {
      // The GPS_LOST and STALL tests call onFix this way. It must stay a pure
      // health feed: no position, no arming, no warning.
      final health = boardingAtDadar();
      expect(health.onFix(t0, usable: true), isEmpty);
      expect(
        spoken(
          health.onFix(
            t0.add(const Duration(minutes: 4)),
            usable: true,
            lat: parel.lat,
            lng: parel.lng,
          ),
        ),
        isEmpty,
      );
    });
  });
}

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
