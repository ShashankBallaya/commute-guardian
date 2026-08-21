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

  test('the timeout still clears the longest real announcement', () {
    // MEASURED, NOT GUESSED. The welcome ran 14046 ms on the 21 Aug iPhone
    // ride, 17380 ms on the 3T for Shahad to Kalyan, and 19186 ms on the 3T
    // for Titwala to Kalyan, where it tripped the old 20 s bound 400 ms before
    // the engine's own completion landed. A wait that gives up on a HEALTHY
    // utterance releases the audio session mid-sentence, so the bound must sit
    // clear of the longest real line, not just above it.
    final match = RegExp(
      r'done\.future\.timeout\(\s*(?://[^\n]*\n\s*)*const Duration\(seconds: (\d+)\)',
    ).firstMatch(speakNow);
    expect(match, isNotNull, reason: 'the bound is no longer a plain Duration');
    expect(
      int.parse(match!.group(1)!),
      greaterThanOrEqualTo(25),
      reason: 'the longest measured welcome is 19.2 s, and 20 s already fired '
          'on a healthy utterance',
    );
  });

  group('standing the ladder down', () {
    late String release;

    setUpAll(() {
      final start = source.indexOf('Future<void> _releaseLadderAudio() async {');
      expect(start, greaterThan(-1), reason: '_releaseLadderAudio is gone');
      final end = source.indexOf('\n  }', start);
      release = source.substring(start, end);
      expect(
        release,
        contains('_finishUtterance()'),
        reason: 'the window no longer reaches the end of the method',
      );
    });

    test('THE WORDS STOP BEFORE THE SESSION MOVES', () {
      // The 21 Aug evening bench in one property. Reconfiguring the session
      // under a live utterance kills the iOS synthesizer: the ack landed 3.9 s
      // into the check-in, the bounded wait gave up on schedule at 20.0 s, and
      // the NEXT line produced no `VOICE started` at all. A queue that
      // advances in silence is not a working announcer.
      final stop = release.indexOf('_tts.stop()');
      final configure = release.indexOf('_session?.configure(');
      expect(stop, greaterThan(-1), reason: 'the ladder line is never stopped');
      expect(configure, greaterThan(-1), reason: 'the profile is never restored');
      expect(
        stop,
        lessThan(configure),
        reason: 'reconfiguring under a live utterance is the defect itself',
      );
    });

    test('the waiter is released LAST, after the profile is back', () {
      // Completing the waiter lets the queue advance. If that happens before
      // the duck profile is restored, the next line starts speaking into the
      // very reconfigure that just killed this one, and the bug simply moves
      // one announcement down the queue.
      final configure = release.indexOf('_session?.configure(');
      final finish = release.indexOf('_finishUtterance()');
      expect(finish, greaterThan(-1));
      expect(
        finish,
        greaterThan(configure),
        reason: 'releasing the queue before the profile is back just moves '
            'the failure to the next announcement',
      );
    });

    test('the release is guarded by identical, not by a null check', () {
      // `_tts.stop()` fires the cancel handler on some platforms, which
      // already released this waiter and let the queue move on to a NEW
      // utterance. Completing blindly would cut that innocent next line off
      // before it had spoken a word: the fix causing the bug it fixes.
      expect(
        release,
        contains('identical(_utteranceDone, waiter)'),
        reason: 'a bare null check here can cut off the next announcement',
      );
    });
  });
}
