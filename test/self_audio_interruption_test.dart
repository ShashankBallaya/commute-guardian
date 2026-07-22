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

  _sustainedToneTests();
}

void _sustainedToneTests() {
  test('an interruption while our wake alarm loops is ours, however late it '
      'arrives (the 22 Jul iPhone ladder that silenced itself)', () {
    final filter = SelfAudioInterruptionFilter();
    final t0 = DateTime(2026, 7, 22, 14, 54, 2);

    // The tone starts. On iOS it is a native loop that holds the session for
    // as long as the ladder climbs.
    filter.setSustainedOwnAudio(active: true);
    filter.noteOwnAudioStarted(t0);

    // The real deltas from that ride: 192 ms, then 1.94 s, then 11.5 s after
    // a rung. Only the first is inside the 1 s window; all three are our own
    // tone, and all three stood the ladder down.
    for (final delta in [
      const Duration(milliseconds: 192),
      const Duration(milliseconds: 1940),
      const Duration(milliseconds: 11500),
      const Duration(minutes: 3),
    ]) {
      expect(
        filter.shouldIgnore(begin: true, now: t0.add(delta)),
        isTrue,
        reason: 'a $delta interruption during our own loop is not a call',
      );
      expect(filter.shouldIgnore(begin: false, now: t0.add(delta)), isTrue);
    }
  });

  test('a real call once our tone has stopped still counts (decision 8 is '
      'untouched)', () {
    final filter = SelfAudioInterruptionFilter();
    final t0 = DateTime(2026, 7, 22, 14, 54, 2);
    filter.setSustainedOwnAudio(active: true);
    filter.noteOwnAudioStarted(t0);
    expect(filter.shouldIgnore(begin: true, now: t0), isTrue);
    filter.shouldIgnore(begin: false, now: t0.add(const Duration(seconds: 1)));

    // Ladder acked, tone stopped. The rider's phone rings a minute later.
    filter.setSustainedOwnAudio(active: false);
    expect(
      filter.shouldIgnore(
        begin: true,
        now: t0.add(const Duration(minutes: 1)),
      ),
      isFalse,
      reason: 'on a call means awake; the filter must not swallow that',
    );
  });
}
