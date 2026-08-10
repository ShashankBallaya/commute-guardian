import 'dart:io';

import 'package:commute_guardian/services/pocket_pulse.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pocket Pulse's decision engine.
///
/// Most of these pin an ABSENCE: a chime that must not fire, a burst that must
/// not arrive. That is the shape of this feature. It is the least important
/// sound the app makes, sharing a session with the most important one, so
/// nearly every rule is about staying out of the way.
void main() {
  final t0 = DateTime(2026, 7, 30, 19, 0, 0);

  /// Ticks the engine every 5 seconds, as the service does, and returns the
  /// instants at which a chime came out.
  List<DateTime> chimesOver(
    PocketPulse pulse, {
    required Duration span,
    DateTime? from,
    bool Function(DateTime now)? announcerBusy,
    void Function(PocketPulse pulse, DateTime now)? each,
  }) {
    final start = from ?? t0;
    final chimes = <DateTime>[];
    for (var s = 5; s <= span.inSeconds; s += 5) {
      final now = start.add(Duration(seconds: s));
      each?.call(pulse, now);
      final actions = pulse.onTick(
        now,
        announcerBusy: announcerBusy?.call(now) ?? false,
      );
      if (actions.any((a) => a is PulseChime)) chimes.add(now);
    }
    return chimes;
  }

  test('off means silent, forever', () {
    final pulse = PocketPulse();
    expect(chimesOver(pulse, span: const Duration(hours: 2)), isEmpty);
  });

  test('THE FIRST CHIME IS ONE INTERVAL IN, never at the start', () {
    // The welcome line owns the moment a ride starts, and a rider who has just
    // pocketed the phone does not yet need telling it is still there.
    final pulse = PocketPulse(intervalS: 180, startedAt: t0);
    final chimes = chimesOver(pulse, span: const Duration(minutes: 10));

    expect(chimes.first, t0.add(const Duration(minutes: 3)));
    expect(chimes.length, 3);
  });

  test('the cadence holds over a long ride', () {
    final pulse = PocketPulse(intervalS: 180, startedAt: t0);
    final chimes = chimesOver(pulse, span: const Duration(minutes: 90));

    expect(chimes.length, 30);
    for (var i = 1; i < chimes.length; i++) {
      expect(chimes[i].difference(chimes[i - 1]), const Duration(minutes: 3));
    }
  });

  group('against the wake ladder', () {
    test('A LIVE LADDER DROPS PULSES ENTIRELY', () {
      // The rank the owner ratified: Wake-up > Announcement > Pulse. The alarm
      // is the product; nothing may compete with it.
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      pulse.onWakeLadder(true, t0);

      expect(chimesOver(pulse, span: const Duration(minutes: 10)), isEmpty);
    });

    test('AND THERE IS NO CATCH-UP BURST WHEN IT STANDS DOWN', () {
      // This is the one that matters most. A rider who just silenced an alarm
      // is holding the phone, wide awake, and the worst possible response is
      // five owed chimes arriving at once in their ear.
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      pulse.onWakeLadder(true, t0);

      // Deliberately NOT on a slot boundary. An earlier draft stood the ladder
      // down at exactly five minutes, which on a 60 s interval is also a
      // scheduled slot, so the test could not tell "resumed correctly" apart
      // from "fired the owed one".
      final standDown = t0.add(const Duration(minutes: 4, seconds: 30));
      final chimes = chimesOver(
        pulse,
        span: const Duration(minutes: 10),
        each: (p, now) {
          if (now == standDown) p.onWakeLadder(false, now);
        },
      );

      // Silent throughout the ladder, then ONE chime at the next scheduled
      // slot, and the normal cadence from there. Never the five that were owed.
      expect(chimes.every((c) => c.isAfter(standDown)), isTrue);
      expect(chimes.first, t0.add(const Duration(minutes: 5)));
      expect(chimes[1], t0.add(const Duration(minutes: 6)));
    });

    test('a deferred chime does not survive a ladder going live', () {
      // Otherwise the deferral becomes a back door for exactly the burst the
      // test above forbids.
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      final chimes = chimesOver(
        pulse,
        span: const Duration(minutes: 4),
        // Busy right across the first slot, so a chime is waiting...
        announcerBusy: (now) =>
            now.isAfter(t0.add(const Duration(seconds: 55))) &&
            now.isBefore(t0.add(const Duration(seconds: 75))),
        // ...and the ladder goes live while it waits.
        each: (p, now) {
          if (now == t0.add(const Duration(seconds: 70))) {
            p.onWakeLadder(true, now);
          }
        },
      );
      expect(chimes, isEmpty);
      expect(pulse.isDeferred, isFalse);
    });
  });

  group('against an announcement', () {
    test('a busy announcer DEFERS the chime rather than dropping it', () {
      // An announcement is bounded, so waiting is honest and the chime still
      // lands. This is the asymmetry with the ladder, and it is deliberate.
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      final busyUntil = t0.add(const Duration(seconds: 80));
      final chimes = chimesOver(
        pulse,
        span: const Duration(minutes: 3),
        announcerBusy: (now) => now.isBefore(busyUntil),
      );

      // Due at 60 s, spoken over until 80 s, so it lands on the first tick the
      // announcer is free rather than never.
      expect(chimes.first, t0.add(const Duration(seconds: 80)));
    });

    test('a slot waiting longer than a minute is abandoned, and says so', () {
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      final actions = <PulseAction>[];
      for (var s = 5; s <= 200; s += 5) {
        actions.addAll(
          pulse.onTick(t0.add(Duration(seconds: s)), announcerBusy: true),
        );
      }
      expect(actions.whereType<PulseChime>(), isEmpty);
      expect(
        actions.whereType<PulseNote>().map((n) => n.reason),
        contains('pulse slot abandoned: announcer busy 60s'),
      );
    });

    test('a deferral spanning several slots still produces ONE chime', () {
      // The collapse rule. Missed slots are lost, never banked.
      //
      // Crowd mode's 45 s, because two slots have to fit inside the 60 s
      // deferral cap for a deferral to span them at all. At 3 minutes the cap
      // abandons the slot long before the next one is due, which is its own
      // test above.
      final pulse = PocketPulse(intervalS: 45, startedAt: t0);
      final chimes = chimesOver(
        pulse,
        span: const Duration(seconds: 130),
        // Busy across BOTH the 45 s and 90 s slots, but for less than the cap.
        announcerBusy: (now) =>
            now.isAfter(t0.add(const Duration(seconds: 40))) &&
            now.isBefore(t0.add(const Duration(seconds: 95))),
      );
      expect(chimes.length, 1);
      expect(chimes.single, t0.add(const Duration(seconds: 95)));
    });
  });

  test('a call drops pulses, and ending it does not catch up either', () {
    final pulse = PocketPulse(intervalS: 60, startedAt: t0);
    pulse.onCallState(true, t0);
    // Off a slot boundary, for the reason the ladder test explains.
    final hangUp = t0.add(const Duration(minutes: 3, seconds: 40));
    final chimes = chimesOver(
      pulse,
      span: const Duration(minutes: 8),
      each: (p, now) {
        if (now == hangUp) p.onCallState(false, now);
      },
    );
    expect(chimes.every((c) => c.isAfter(hangUp)), isTrue);
    expect(chimes.first, t0.add(const Duration(minutes: 4)));
  });

  group('changing the interval mid-ride', () {
    test(
      're-anchors from now, so the new cadence starts being true at once',
      () {
        // A rider flipping crowd mode on wants 45 seconds NOW, not after the old
        // three minutes drains.
        final pulse = PocketPulse(intervalS: 180, startedAt: t0);
        final switchAt = t0.add(const Duration(minutes: 1));
        final chimes = chimesOver(
          pulse,
          span: const Duration(minutes: 4),
          each: (p, now) {
            if (now == switchAt) p.setInterval(45, now);
          },
        );
        expect(chimes.first, switchAt.add(const Duration(seconds: 45)));
      },
    );

    test('setting the SAME interval does not reset the cadence', () {
      // The settings write-through path can fire more than once; it must not
      // silently push the next chime away each time.
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      final chimes = chimesOver(
        pulse,
        span: const Duration(minutes: 3),
        each: (p, now) => p.setInterval(60, now),
      );
      expect(chimes.first, t0.add(const Duration(minutes: 1)));
      expect(chimes.length, 3);
    });

    test('switching off silences it immediately', () {
      final pulse = PocketPulse(intervalS: 60, startedAt: t0);
      final chimes = chimesOver(
        pulse,
        span: const Duration(minutes: 5),
        each: (p, now) {
          if (now == t0.add(const Duration(seconds: 30))) {
            p.setInterval(null, now);
          }
        },
      );
      expect(chimes, isEmpty);
      expect(pulse.nextDueAt, isNull);
    });
  });

  test('suppression notes fire on transitions only, never per slot', () {
    // A crowd-mode ride drops a slot every 45 seconds while a ladder climbs.
    // One line saying why, not eighty.
    final pulse = PocketPulse(intervalS: 45, startedAt: t0);
    final notes = <String>[
      ...pulse
          .onWakeLadder(true, t0)
          .whereType<PulseNote>()
          .map((n) => n.reason),
    ];
    for (var s = 5; s <= 600; s += 5) {
      notes.addAll(
        pulse
            .onTick(t0.add(Duration(seconds: s)), announcerBusy: false)
            .whereType<PulseNote>()
            .map((n) => n.reason),
      );
    }
    notes.addAll(
      pulse
          .onWakeLadder(false, t0.add(const Duration(seconds: 605)))
          .whereType<PulseNote>()
          .map((n) => n.reason),
    );

    expect(notes, [
      'pulse suppressed: wake ladder live',
      'pulse resumed: ladder stood down',
    ]);
  });

  group('THE RIDE LOG MAY NOT CLAIM AN OUTPUT THE PLATFORM CANNOT PRODUCE', () {
    // An iPhone ride log said "PULSE every 45s, with vibration" on 10 Aug 2026
    // (21:28, Shahad to Dombivli, in Hindi). iOS forbids background haptics, a
    // founding premise of this project, so PulseOutput.buzz returns at its first
    // line there and that buzz could not physically have happened. A log that
    // claims an output it cannot produce sends the next diagnosis after a broken
    // vibrator instead of a dead control.
    //
    // Read from the source because the flag lives in the service isolate, which
    // needs a device and a foreground task to instantiate.

    /// The assignment that takes the RIDER'S preference, not the field's
    /// declaration.
    ///
    /// The first version of this guard used firstMatch and caught
    /// `bool _pulseVibrate = true;` instead, so it failed against correct code.
    /// Same family as every other source-reading guard this project has had to
    /// repair: the check must name the thing it means, not the first text that
    /// looks like it.
    String? platformAnd(String source) {
      for (final m in RegExp(r'_pulseVibrate = ([^;]+);').allMatches(source)) {
        final rhs = m.group(1)!;
        if (rhs.contains('pulseVibrate')) return rhs;
      }
      return null;
    }

    test('the vibrate flag is ANDed with the platform, not just honoured', () {
      final rhs = platformAnd(
        File('lib/services/geofence_chain_service.dart').readAsStringSync(),
      );

      expect(
        rhs,
        isNotNull,
        reason: 'the parameter must be assigned somewhere',
      );
      expect(
        rhs,
        contains('Platform.isAndroid'),
        reason: 'iOS cannot buzz, so it must not be recorded as buzzing',
      );
    });

    test('the guard can still fail', () {
      // The shape the bug actually had, plus the declaration that fooled the
      // first draft of the guard.
      const broken = '''
  bool _pulseVibrate = true;
  _pulseVibrate = pulseVibrate;''';
      expect(platformAnd(broken), 'pulseVibrate');
      expect(platformAnd(broken), isNot(contains('Platform.isAndroid')));
    });
  });
}
