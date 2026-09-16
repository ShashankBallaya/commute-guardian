import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TTS pre-warm (handover section 4.2), and the ordering rule that makes it
/// safe.
///
/// READ FROM THE SOURCE, and the reason is worth stating rather than hiding.
/// `GeofenceChainService` builds its own `FlutterTts` inline, so there is no
/// seam to inject a fake through, and the failure this guards against is
/// INVISIBLE at runtime anyway: a welcome spoken at volume zero looks like a
/// working ride in every log and every test. Making `_tts` injectable means
/// refactoring the most audio-critical path in the app, which is its own
/// change with its own bench. Until then, a source-order check is a weaker
/// guard than a behavioural one and a much stronger guard than none.
void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/services/geofence_chain_service.dart',
    ).readAsStringSync();
  });

  test('THE VOLUME IS RESTORED BEFORE THE WELCOME IS QUEUED', () {
    // The pre-warm drops the volume to speak one silent space. The drop, the
    // space and the restore are ONE job on the announcer queue, so the welcome
    // can only run after the restore. Reordering these, or moving the restore
    // off the queue, speaks the welcome at volume zero. That is a silent first
    // impression on the one line whose whole job is to prove through the
    // earphones that the audio path works.
    //
    // The queue was called `_speaking` until 13 Aug 2026, when it was merged
    // with the clip queue, and `_audioChain` until 16 Sep 2026, when it became
    // an `AudioQueue` that an urgent wake line may jump. Only the name changed
    // here; the ordering this test pins did not.
    final warm = source.indexOf('Future<void> _preWarmTts()');
    expect(warm, greaterThan(-1), reason: 'the pre-warm is gone');

    final body = source.substring(warm, source.indexOf('\n  }', warm));
    final drop = body.indexOf('setVolume(0)');
    final speak = body.indexOf("_speakNow(' ')");
    final restore = body.indexOf('setVolume(1)');

    expect(drop, greaterThan(-1));
    expect(speak, greaterThan(drop), reason: 'volume drops before the space');
    expect(restore, greaterThan(speak), reason: 'volume restores after it');
  });

  test('IT IS ONE JOB, so no urgent line can land inside the muted window',
      () {
    // ADDED 16 SEP 2026 WITH THE PRIORITY QUEUE, and it is the reason the
    // pre-warm was rewritten rather than left alone. It used to be three jobs
    // (mute, space, restore), which left two gaps a jumping wake line could be
    // inserted into, and both gaps sit between the mute and the restore. A
    // wake line spoken at volume zero is the silent welcome this file guards,
    // aimed at the one sentence that must never be missed.
    final warm = source.indexOf('Future<void> _preWarmTts()');
    final body = source.substring(warm, source.indexOf('\n  }', warm));
    // COMMENTS STRIPPED. This method's own comments talk about urgent lines
    // and about _speak, so a guard read off the raw text would be answering
    // the prose rather than the code. See the substring-guard note: this is
    // the repeat mistake in this repo.
    final code = body
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      '_audio.add('.allMatches(code).length,
      1,
      reason: 'the mute, the space and the restore must be ONE job',
    );
    expect(
      code,
      isNot(contains('urgent')),
      reason: 'the pre-warm must never jump the queue itself',
    );
    // _speakNow, not _speak: a job that enqueues a job and awaits it cannot
    // complete, because the queue runs one job at a time. The boundary matters
    // because `_speakNow(` contains `_speak` but not `_speak(`.
    expect(
      RegExp(r'[^A-Za-z_]_speak\(').hasMatch(code),
      isFalse,
      reason: 'enqueueing from inside a job deadlocks the announcer',
    );
  });

  test('the pre-warm goes through the speak path, not the plugin', () {
    // _speakNow is the speak path minus the enqueue, which is what a caller
    // already inside a queue job must use. Calling `_tts.speak` directly would
    // skip the audio-session discipline
    // every other utterance obeys, and inside the plugin that call activates
    // the session. Doing that raw at ride start is the shape of the 13 Jul
    // bench bug, where Travel Mode grabbed audio focus the moment it began.
    final warm = source.indexOf('Future<void> _preWarmTts()');
    final body = source.substring(warm, source.indexOf('\n  }', warm));
    expect(body, contains("_speakNow(' ')"));
    expect(body, isNot(contains('_tts.speak')));
  });

  test('IT RUNS BEFORE THE GEOFENCES, or it buys nothing', () {
    // The point is the engine loading WHILE the regions are registered.
    // Fired next to the welcome instead, it would move the cold start by a
    // few milliseconds and be pure ceremony.
    final warm = source.indexOf('unawaited(_preWarmTts())');
    final geofences = source.indexOf('Geofencing.instance.setup');
    final welcome = source.indexOf('SPEAK welcome');

    expect(warm, greaterThan(-1));
    expect(warm, lessThan(geofences), reason: 'warm while regions register');
    expect(warm, lessThan(welcome));
  });

  test('every utterance reports how long it took to become sound', () {
    // The instrument section 4.2 always needed and never had. The ride logs
    // record when an announcement was DECIDED; the gap between that and the
    // first sound was invisible, so six replays showing no problem was not
    // evidence there was none.
    expect(source, contains('_tts.setStartHandler(_noteSpeechStarted)'));
    expect(source, contains('VOICE started'));

    // ONE STAMP, ABOVE THE PLATFORM BRANCH.
    //
    // This used to assert TWO, because `_spokenAt` was set separately inside
    // the Android arm and the iOS arm, and the risk being guarded was that a
    // later edit would drop one and leave the number missing on exactly the
    // platform nobody was looking at. The 21 Aug 2026 fix for the Kalyan
    // announcer wedge hoisted the stamp (and the completer, and the bounded
    // wait) out of the branch entirely, which removes that risk by
    // construction rather than by counting. The property is now the stronger
    // one: it is stamped once, unconditionally, on every path.
    //
    // String implements Pattern, so this is the built-in allMatches.
    expect('_spokenAt = DateTime.now();'.allMatches(source).length, 1);

    final speakNow = source.substring(
      source.indexOf('Future<void> _speakNow(String text) async {'),
    );
    final stamp = speakNow.indexOf('_spokenAt = DateTime.now();');
    final branch = speakNow.indexOf('if (Platform.isAndroid)');
    expect(stamp, greaterThan(-1));
    expect(
      stamp,
      lessThan(branch),
      reason: 'a stamp inside one arm reports the latency of one platform',
    );
  });
}
