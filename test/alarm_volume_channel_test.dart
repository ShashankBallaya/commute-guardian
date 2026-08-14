// THE 14 AUG 2026 BENCH BUG, and the one place it can be tested.
//
// alarm_volume_test.dart already pins the DECISION: a volume we took is given
// back, a volume we did not take is left alone. All four of those tests passed
// on the evening the app lowered the rider's volume from 85 percent to 65,
// because they drive a fake client. The lie was inside the real one.
//
// AND THE REAL ONE CANNOT BE TESTED HERE. `raiseAlarmVolume` opens with
// `if (!Platform.isIOS) return null`, so a method-channel test on a desktop
// host returns null before reaching any logic. The first draft of this file was
// exactly that: five channel tests, four of which passed against code that
// never ran. So the decision was extracted to volumeTakenFrom, and this tests
// the decision.

import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/services/alarm_volume_answer.dart';

void main() {
  test('THE VOLUME REMEMBERED IS THE ONE NATIVE MEASURED', () {
    expect(
      volumeTakenFrom({
        'note': 'ALARM VOLUME: raised from 12% to 70% for the alarm.',
        'raisedFrom': 0.12,
      }),
      closeTo(0.12, 1e-9),
    );
  });

  test('A RIDER ALREADY LOUD ENOUGH YIELDS NULL, which is the 14 Aug fault '
      'itself: anything else gets written onto their phone', () {
    expect(
      volumeTakenFrom({
        'note': 'ALARM VOLUME: 85% already at or above the 70% floor.',
      }),
      isNull,
    );
  });

  test('a platform with no slider yields null', () {
    expect(
      volumeTakenFrom({
        'note': 'ALARM VOLUME: 30%, BUT NO SYSTEM SLIDER, left alone.',
      }),
      isNull,
    );
  });

  test('an unreadable volume yields null rather than a guess', () {
    expect(
      volumeTakenFrom({'note': 'ALARM VOLUME: could not read, left alone.'}),
      isNull,
    );
  });

  test('a missing answer yields null', () {
    expect(volumeTakenFrom(null), isNull);
  });

  test('AN INT FROM THE CHANNEL IS NOT A CRASH. A whole value can arrive as '
      'an int, and a cast would throw where a missing key returns null', () {
    expect(volumeTakenFrom({'raisedFrom': 1}), 1.0);
    expect(volumeTakenFrom({'raisedFrom': 0}), 0.0);
  });

  test('a zero slider is REMEMBERED, not discarded', () {
    // The whole feature exists because his slider reads zero. Treating 0.0 as
    // "nothing to remember" would leave the phone at 70 percent afterwards.
    expect(volumeTakenFrom({'raisedFrom': 0.0}), 0.0);
  });

  test('nonsense is refused', () {
    expect(volumeTakenFrom({'raisedFrom': 'loud'}), isNull);
    expect(volumeTakenFrom({'raisedFrom': double.nan}), isNull);
    expect(volumeTakenFrom({'raisedFrom': -1.0}), isNull);
  });

  test('a value above 1.0 is clamped rather than replayed onto a slider', () {
    expect(volumeTakenFrom({'raisedFrom': 1.4}), 1.0);
  });
}
