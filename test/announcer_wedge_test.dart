import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE 21 AUG 2026 KALYAN SILENCE, guarded from the source.
///
/// The rider acked the wake ladder mid-sentence. Standing it down reconfigured
/// the iOS audio session under a live `AVSpeechSynthesizer`, and iOS fired
/// neither `didFinish` nor `didCancel`. `flutter_tts` resolves the `speak()`
/// future from exactly those two callbacks, so the future never completed,
/// `_audioChain` wedged, and `_pendingSpeaks` stuck at 1. The arrival at the
/// destination, the wind-down and the farewell were all decided, queued, and
/// never spoken. The only trace in 4751 log lines was one line:
/// `PULSE slot abandoned: announcer busy 60s`.
///
/// READ FROM THE SOURCE, for the reason `tts_prewarm_test.dart` states at
/// length: `GeofenceChainService` builds its own `FlutterTts` inline, there is
/// no seam to inject a fake through, and this service cannot be built under
/// the test binding at all. A behavioural test would be better. This is the
/// guard that is available, and it is much stronger than none.
///
/// It is also the only kind of guard that can catch a REGRESSION here, because
/// the failure is invisible at runtime: a wedged announcer looks exactly like
/// a quiet stretch of track.
void main() {
  late String source;
  late String speakNow;

  setUpAll(() {
    source = File(
      'lib/services/geofence_chain_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _speakNow(String text) async {');
    expect(start, greaterThan(-1), reason: '_speakNow is gone or renamed');
    // To the end of the method, which is the first line that closes at the
    // method's own indent. Anchored on the `finally` that follows the branch
    // so a later edit inside the body cannot silently shrink the window this
    // whole file reads.
    final end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    speakNow = source.substring(start, end);
    expect(
      speakNow,
      contains('_pendingSpeaks--'),
      reason: 'the window no longer reaches the end of the method',
    );
  });

  test('THE BOUNDED WAIT IS NOT INSIDE A PLATFORM BRANCH', () {
    // The whole defect in one property. The timeout used to live in the
    // `if (Platform.isAndroid)` arm, on the reasoning that iOS honours
    // awaitSpeakCompletion and could simply be awaited. It does, right up
    // until the utterance is killed rather than finished.
    final timeout = speakNow.indexOf('done.future.timeout(');
    expect(timeout, greaterThan(-1), reason: 'the bounded wait is gone');

    final branch = speakNow.indexOf('if (Platform.isAndroid)');
    expect(branch, greaterThan(-1), reason: 'the platform branch is gone');

    // ANCHOR ON THE END OF THE ELSE ARM, NOT THE IF ARM. The first draft of
    // this test looked for `\n        }` after the branch, which matches the
    // brace that opens `} else {`. That proved only that the wait came after
    // the ANDROID arm, and would have passed with the wait sitting inside the
    // iOS one. Sixth instance of that mistake in this repo; see the
    // substring-guard note.
    final elseAt = speakNow.indexOf('} else {', branch);
    expect(elseAt, greaterThan(branch), reason: 'the iOS arm is gone');
    final elseEnd = speakNow.indexOf('\n        }', elseAt);
    expect(elseEnd, greaterThan(elseAt));

    // The WHOLE if/else closes before the wait begins: the wait is common
    // code, reached on both platforms, on every path through the branch.
    expect(
      timeout,
      greaterThan(elseEnd),
      reason: 'the bounded wait fell back inside a platform arm, which is '
          'the exact shape of the 21 Aug 2026 Kalyan silence',
    );
  });

  test('the completer is seeded before the branch, so BOTH arms feed it', () {
    final seed = speakNow.indexOf('_utteranceDone = done');
    final branch = speakNow.indexOf('if (Platform.isAndroid)');
    expect(seed, greaterThan(-1));
    expect(
      seed,
      lessThan(branch),
      reason: 'a completer created inside one arm cannot bound the other',
    );
  });

  test('iOS does NOT await the plugin future, because that is what hangs', () {
    // The Android arm keeps `await _tts.speak(text)`: under QUEUE_ADD it
    // returns at once and the 30 Jul 2026 duck fix depends on that shape.
    // The iOS arm must not await, or the timeout below it is unreachable.
    final branch = speakNow.indexOf('if (Platform.isAndroid)');
    final elseAt = speakNow.indexOf('} else {', branch);
    expect(elseAt, greaterThan(-1), reason: 'the iOS arm is gone');

    final iosArm = speakNow.substring(elseAt, speakNow.indexOf('\n        }', elseAt));
    expect(
      iosArm,
      contains('unawaited('),
      reason: 'the iOS arm must not block the chain on the plugin future',
    );
    expect(
      iosArm.contains('await _tts.speak'),
      isFalse,
      reason: 'awaiting speak() on iOS is the wedge itself: with neither '
          'didFinish nor didCancel, that future never completes',
    );
  });

  test('every exit from the speak path releases the waiter', () {
    // A completer left set is the same wedge by a slower route: the next
    // utterance overwrites it, but this one already returned holding the
    // chain. The catch arm swallows errors to keep the queue alive, so it
    // must release too.
    final catchAt = speakNow.indexOf('} catch (error) {');
    expect(catchAt, greaterThan(-1));
    final catchArm = speakNow.substring(catchAt, speakNow.indexOf('} finally {', catchAt));
    expect(
      catchArm,
      contains('_finishUtterance()'),
      reason: 'a swallowed error must not leave the waiter hanging',
    );
  });

  test('the timeout still fits the longest real announcement', () {
    // The welcome ran 14046 ms on the 21 Aug ride and the Dadar interchange
    // script 10471 ms. A bound below either would cut the sentence the rider
    // most needs. This pins the headroom, not the number.
    final match = RegExp(
      r'done\.future\.timeout\(\s*const Duration\(seconds: (\d+)\)',
    ).firstMatch(speakNow);
    expect(match, isNotNull, reason: 'the bound is no longer a plain Duration');
    expect(
      int.parse(match!.group(1)!),
      greaterThanOrEqualTo(20),
      reason: 'the welcome alone speaks for 14.0 s',
    );
  });
}
