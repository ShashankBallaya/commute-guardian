import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/services/wake_alert_output.dart';

/// The iOS vibration burst, licensed by `docs/adr/0003` on 12 Aug 2026.
///
/// These run on the test host, which is neither Android nor iOS, and that is
/// exactly why the burst is gated on HAVING THE HOOK rather than on asking
/// what platform it is standing on. Android leaves at the first line of
/// [WakeAlertOutput.vibrate] and hands its pattern to the platform in one
/// call; everything below is the iOS shape, which is the only one with a
/// burst to cancel.
///
/// The tone paths are deliberately not exercised: they need audioplayers and
/// a device. The player is constructed lazily so that touching none of them
/// constructs none of it.
void main() {
  /// Counts native buzz requests the way AppDelegate would receive them.
  ({WakeAlertOutput output, List<String> log, int Function() buzzes}) build() {
    var buzzes = 0;
    final log = <String>[];
    final output = WakeAlertOutput(
      log: log.add,
      onIosToneCommand: (_, _) {},
      onIosVibrate: () => buzzes++,
    );
    return (output: output, log: log, buzzes: () => buzzes);
  }

  group('CANCEL ON ACK', () {
    // FIRST TEST ON PURPOSE, and the reason the burst is a burst rather than
    // one call: iOS gets one fixed buzz with no duration and no intensity, so
    // the ladder can only be insistent by repeating. A repeat that outlives
    // the acknowledgment buzzes at a rider who has already said they are
    // awake, which is worse than not buzzing at all: it teaches them that
    // answering the alarm does nothing.

    test('an ack part way through a burst stops the rest of it', () async {
      final t = build();

      final burst = t.output.vibrate();
      // Mid-burst: after the first buzz has gone out and while the gap before
      // the second is still running.
      await Future<void>.delayed(WakeAlertOutput.iosBurstGap ~/ 2);
      expect(t.buzzes(), 1, reason: 'the burst must have started');

      t.output.cancelVibration();
      await burst;

      expect(
        t.buzzes(),
        1,
        reason: 'the two buzzes after the ack must never have been requested',
      );

      // And nothing arrives late, either: a cancel that only skipped the next
      // buzz but left the loop running would show up here.
      await Future<void>.delayed(WakeAlertOutput.iosBurstGap * 3);
      expect(t.buzzes(), 1);

      // THE RIDE LOG MUST SAY SO. The 12 Aug bench fired three bursts and the
      // log recorded none of them, so "he felt two" could not be checked
      // against what was requested. A cancelled burst is also how the ack is
      // judged from a log afterwards.
      expect(t.log, ['WAKE buzz burst cancelled after 1 of 3.']);
    });

    test('stopTone cancels the burst, which is how the ack actually gets here',
        () async {
      // The service never calls cancelVibration on the ack path. It calls the
      // engine, the engine answers StopTone, and the shell stops the tone.
      // Cancelling inside stopTone is what makes that enough, so nothing
      // outside this class has to remember the burst exists.
      final t = build();

      final burst = t.output.vibrate();
      await Future<void>.delayed(WakeAlertOutput.iosBurstGap ~/ 2);
      await t.output.stopTone();
      await burst;

      expect(t.buzzes(), 1);
    });

    test('a cancel kills the burst in flight and NOT the next ladder', () async {
      // Written the other way round first, expecting a cancel to suppress a
      // later burst too, and the code was right and the test was wrong. A
      // cancel answers the burst that is sounding now. A rider who acks one
      // ladder and then sleeps past the NEXT critical station must get the
      // full alarm again, so a cancel may not leave anything latched off.
      final t = build();

      final first = t.output.vibrate();
      await Future<void>.delayed(WakeAlertOutput.iosBurstGap ~/ 2);
      t.output.cancelVibration();
      await first;
      expect(t.buzzes(), 1);

      await t.output.vibrate();
      expect(t.buzzes(), 1 + WakeAlertOutput.iosBurstCount);
    });
  });

  group('THE BURST ITSELF', () {
    test('runs to its full count when nothing interrupts it', () async {
      final t = build();

      await t.output.vibrate();

      expect(t.buzzes(), WakeAlertOutput.iosBurstCount);
      // The log states the gap as well as the count, because the gap is the
      // setting that changed when the owner felt two buzzes instead of three,
      // and a log that only said "3" would not have told anyone which build
      // they were feeling.
      expect(t.log, ['WAKE buzz burst requested: 3 at 800ms.']);
    });

    test('is spaced, not fired all at once', () async {
      final t = build();
      final started = DateTime.now();

      await t.output.vibrate();

      // Three buzzes with two gaps between them. A burst that fired them in
      // one turn would be felt as a single buzz and would be indistinguishable
      // from Pocket Pulse's one tap, which is the thing it must never be
      // confused with.
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(WakeAlertOutput.iosBurstGap * 2),
      );
    });

    test('a second burst supersedes the first rather than doubling it', () async {
      // Two ladder rungs land close together, or a tick and a post-call firm
      // rung arrive in the same second. Overlapping bursts would buzz at
      // twice the density the ladder asked for, which on the only axis iOS
      // has IS the escalation, so it would silently skip a rung.
      final t = build();

      final first = t.output.vibrate();
      await Future<void>.delayed(WakeAlertOutput.iosBurstGap ~/ 2);
      final second = t.output.vibrate();
      await Future.wait([first, second]);

      expect(
        t.buzzes(),
        WakeAlertOutput.iosBurstCount + 1,
        reason: 'one buzz from the abandoned burst, then a whole second one',
      );
    });

    test('does nothing when there is no hook, which is every non-iOS build', () async {
      final log = <String>[];
      final output = WakeAlertOutput(log: log.add);

      await output.vibrate();

      // No throw, no log line. The hook is the platform gate: the shell wires
      // it only where the native side can answer.
      expect(log, isEmpty);
    });
  });
}
