import 'package:commute_guardian/services/ride_timeout.dart';
import 'package:flutter_test/flutter_test.dart';

/// The four-hour backstop, the handover's TIMEOUT edge transition (section 4.1)
/// and the last Phase 1 item that was on no other list.
///
/// It is the backstop for the ride that NEVER ARRIVES, which is the one WindDown
/// cannot help with: WindDown ends a ride once the rider has walked away from
/// the platform it announced, and a ride whose geofences all missed never gets
/// that far. On 22 Jul the owner walked home from Shahad with both phones still
/// streaming GPS, and the only thing that ended it was him remembering.
void main() {
  final startedAt = DateTime(2026, 8, 5, 9);

  RideTimeout timeout() => RideTimeout(startedAt: startedAt);

  List<RideTimeoutAction> tickAt(
    RideTimeout engine,
    Duration elapsed, {
    bool wake = false,
    bool windDown = false,
  }) {
    return engine.onTick(
      startedAt.add(elapsed),
      wakeLadderLive: wake,
      windDownLive: windDown,
    );
  }

  test('a normal ride never hears from it', () {
    // The longest run in the bundled data, CSMT to Kasara, is a little over
    // three hours with the stopping pattern. Four hours does not mean a slow
    // train, it means nobody is coming back to end this.
    final engine = timeout();
    for (final minutes in [1, 30, 90, 180, 210, 239]) {
      expect(
        tickAt(engine, Duration(minutes: minutes)),
        isEmpty,
        reason: 'nothing should happen at $minutes min',
      );
    }
  });

  test('at four hours it says so, once, and does not end anything', () {
    final engine = timeout();
    final actions = tickAt(engine, const Duration(hours: 4));

    expect(actions.whereType<RideTimeoutSpeak>(), hasLength(1));
    expect(actions.whereType<RideTimeoutEnd>(), isEmpty);
    // The warning names both the deadline and the way out of it, because a
    // rider who IS still aboard has to be able to act on it.
    final spoken = actions.whereType<RideTimeoutSpeak>().single.text;
    expect(spoken, contains('four hours'));
    expect(spoken, contains('half an hour'));

    // Ticks are five seconds apart. Saying it again every tick for half an
    // hour would be its own kind of failure.
    expect(
      tickAt(
        engine,
        const Duration(hours: 4, seconds: 5),
      ).whereType<RideTimeoutSpeak>(),
      isEmpty,
    );
  });

  test('at four and a half hours it ends the ride, once', () {
    final engine = timeout();
    tickAt(engine, const Duration(hours: 4));

    final ending = tickAt(engine, const Duration(hours: 4, minutes: 30));
    expect(ending.whereType<RideTimeoutEnd>(), hasLength(1));

    // The teardown is asynchronous, so a second End on the next tick would run
    // a second farewell over the first.
    expect(
      tickAt(engine, const Duration(hours: 5)).whereType<RideTimeoutEnd>(),
      isEmpty,
    );
  });

  test('it can end a ride that never heard the warning', () {
    // A phone in a pocket with no earphones, or a service restarted after the
    // warning was due. The end does not depend on the warning having happened.
    final engine = timeout();
    expect(
      tickAt(engine, const Duration(hours: 6)).whereType<RideTimeoutEnd>(),
      hasLength(1),
    );
  });

  test('IT NEVER ENDS A RIDE WHILE THE WAKE LADDER IS LIVE', () {
    // The whole safety argument. An alarm sounding is the app doing the one job
    // it exists for, and a rider asleep past their stop with the ladder
    // climbing is exactly the state that can also be four hours old. A timeout
    // that silenced it would be the worst bug this project could ship.
    final engine = timeout();
    final held = tickAt(engine, const Duration(hours: 5), wake: true);
    expect(held.whereType<RideTimeoutEnd>(), isEmpty);
    // The reason is logged once, not once per tick: at five second ticks that
    // would be 720 identical lines an hour.
    expect(held.whereType<RideTimeoutNote>(), hasLength(1));
    expect(
      tickAt(engine, const Duration(hours: 5, seconds: 5), wake: true),
      isEmpty,
    );

    // And the clock is not cancelled by the hold: the ride ends on the tick
    // after the alarm is answered.
    expect(
      tickAt(
        engine,
        const Duration(hours: 5, minutes: 1),
      ).whereType<RideTimeoutEnd>(),
      hasLength(1),
    );
  });

  test('it never ends a ride the wind-down is already ending', () {
    // That ride is ending by an engine that knows where the rider is standing.
    // Two teardowns racing is how the 4 Aug double-pop happened.
    final engine = timeout();
    expect(
      tickAt(
        engine,
        const Duration(hours: 5),
        windDown: true,
      ).whereType<RideTimeoutEnd>(),
      isEmpty,
    );
    expect(
      tickAt(
        engine,
        const Duration(hours: 5, minutes: 1),
      ).whereType<RideTimeoutEnd>(),
      hasLength(1),
    );
  });

  test('a restarted service inherits the ride clock, not a fresh one', () {
    // The service comes back about a second after the app is swiped out of
    // recents (30 Jul bench), and it calls start() again. Reading the clock at
    // that moment would hand a forgotten ride another four hours, every time.
    // This is why startedAt is required and comes from the shared store.
    final restarted = RideTimeout(startedAt: startedAt);
    expect(
      restarted
          .onTick(
            startedAt.add(const Duration(hours: 4, minutes: 31)),
            wakeLadderLive: false,
            windDownLive: false,
          )
          .whereType<RideTimeoutEnd>(),
      hasLength(1),
    );
  });
}
