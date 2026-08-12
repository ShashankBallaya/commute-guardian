import 'package:commute_guardian/services/wake_suspension.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who may silence the wake ladder, and who may bring it back.
///
/// THE BUG THIS EXISTS TO PREVENT was found while building the rider's wake
/// toggle on 12 Aug 2026, before it shipped. A real call and the toggle both
/// suspend through `WakeEscalation.onCallStateChanged`, which is the right
/// mechanism for both. Wired naively they share one flag, and then a call
/// ENDING while the rider had the alarm switched off resumes the ladder and
/// re-arms an alarm they deliberately turned off: the silent-alarm failure in
/// reverse, an alarm nobody asked for, on a rider who is awake.
///
/// `GeofenceChainService` reaches plugins on construction and cannot be built
/// under the test binding, which is exactly why this rule was lifted out of it.
void main() {
  WakeSuspension when({required bool inRealCall, required bool wakeEnabled}) =>
      WakeSuspension.of(inRealCall: inRealCall, wakeEnabled: wakeEnabled);

  group('EITHER INPUT SUSPENDS', () {
    test('a call suspends an armed alarm', () {
      expect(when(inRealCall: true, wakeEnabled: true).suspended, isTrue);
    });

    test('the rider switching it off suspends it with no call', () {
      expect(when(inRealCall: false, wakeEnabled: false).suspended, isTrue);
    });

    test('nothing suspends an armed alarm on a quiet ride', () {
      expect(when(inRealCall: false, wakeEnabled: true).suspended, isFalse);
    });
  });

  group('ONLY AGREEMENT RESUMES, which is the whole point', () {
    test('A CALL ENDING DOES NOT RE-ARM AN ALARM THE RIDER SWITCHED OFF', () {
      // The exact bug. The call is over, so the naive wiring would resume.
      expect(
        when(inRealCall: false, wakeEnabled: false).suspended,
        isTrue,
        reason: 'the rider turned this off and only the rider turns it back on',
      );
    });

    test('re-arming mid-call stays silent until the call ends', () {
      // The mirror case, and it matters just as much: a rider who re-arms
      // while still talking must not have an alarm start in their ear.
      expect(when(inRealCall: true, wakeEnabled: true).suspended, isTrue);
    });
  });

  group('WHO IS OWED A REPORT', () {
    test('a call owes the rider what they missed', () {
      // An interruption happened TO them.
      expect(when(inRealCall: true, wakeEnabled: true).catchUp, isTrue);
    });

    test('THE RIDER IS OWED NOTHING, because they decided', () {
      // Every catch-up line in SpokenCopy opens "While you were on your call".
      // Speaking it to somebody who switched off their own alarm is a lie, and
      // re-arming is a decision about the rest of the journey rather than a
      // request for a report.
      expect(when(inRealCall: false, wakeEnabled: true).catchUp, isFalse);
      expect(when(inRealCall: false, wakeEnabled: false).catchUp, isFalse);
    });
  });
}
