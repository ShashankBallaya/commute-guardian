import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/services/self_audio_interruption.dart';

void main() {
  final t0 = DateTime(2026, 7, 21, 13, 57, 16);

  test('an interruption right after our own audio started is ours', () {
    final filter = SelfAudioInterruptionFilter();
    filter.noteOwnAudioStarted(t0);

    // The bench reproduction: the clip and the check-in collided, and the
    // interruption landed 243 ms later.
    expect(
      filter.shouldIgnore(
        begin: true,
        now: t0.add(const Duration(milliseconds: 243)),
      ),
      isTrue,
    );
  });

  test('the end of an interruption we ignored is ignored too', () {
    final filter = SelfAudioInterruptionFilter();
    filter.noteOwnAudioStarted(t0);
    filter.shouldIgnore(begin: true, now: t0.add(const Duration(milliseconds: 150)));

    // Otherwise the engine gets a call that ended without ever beginning.
    expect(
      filter.shouldIgnore(begin: false, now: t0.add(const Duration(seconds: 4))),
      isTrue,
    );
  });

  test('a call well after our audio started is a real call', () {
    final filter = SelfAudioInterruptionFilter();
    filter.noteOwnAudioStarted(t0);

    // 520 ms did not reproduce on the bench; seconds later is plainly a call.
    expect(
      filter.shouldIgnore(begin: true, now: t0.add(const Duration(seconds: 5))),
      isFalse,
    );
  });

  test('a call with no audio of ours in flight is a real call', () {
    final filter = SelfAudioInterruptionFilter();

    expect(filter.shouldIgnore(begin: true, now: t0), isFalse);
  });

  test('the end of a real interruption is delivered', () {
    final filter = SelfAudioInterruptionFilter();
    filter.noteOwnAudioStarted(t0);
    filter.shouldIgnore(begin: true, now: t0.add(const Duration(seconds: 5)));

    expect(
      filter.shouldIgnore(begin: false, now: t0.add(const Duration(seconds: 30))),
      isFalse,
    );
  });

  test('a real call after an ignored one is still delivered', () {
    final filter = SelfAudioInterruptionFilter();
    filter.noteOwnAudioStarted(t0);
    filter.shouldIgnore(begin: true, now: t0.add(const Duration(milliseconds: 200)));
    filter.shouldIgnore(begin: false, now: t0.add(const Duration(seconds: 2)));

    // The rider really does take a call a minute later.
    expect(
      filter.shouldIgnore(begin: true, now: t0.add(const Duration(minutes: 1))),
      isFalse,
    );
  });
}
