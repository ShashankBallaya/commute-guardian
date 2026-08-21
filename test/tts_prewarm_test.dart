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
    // The pre-warm drops the volume to speak one silent space. Both the drop
    // and the restore chain onto `_audioChain`, the same queue every utterance
    // uses, so the welcome can only run after the restore. Reordering these,
    // or moving the restore off the chain, speaks the welcome at volume zero.
    // That is a silent first impression on the one line whose whole job is to
    // prove through the earphones that the audio path works.
    //
    // The queue was called `_speaking` until 13 Aug 2026, when it was merged
    // with the clip queue so a clip could not start on top of a half-spoken
    // welcome. Only the name changed here; the ordering this test pins did
    // not.
    final warm = source.indexOf('Future<void> _preWarmTts()');
    expect(warm, greaterThan(-1), reason: 'the pre-warm is gone');

    final body = source.substring(warm, source.indexOf('\n  }', warm));
    final drop = body.indexOf('setVolume(0)');
    final speak = body.indexOf("_speak(' ')");
    final restore = body.indexOf('setVolume(1)');

    expect(drop, greaterThan(-1));
    expect(speak, greaterThan(drop), reason: 'volume drops before the space');
    expect(restore, greaterThan(speak), reason: 'volume restores after it');
    // On the chain, not fired loose: `_audioChain = _audioChain.then` is what
    // orders it against the welcome.
    expect(body, contains('_audioChain = _audioChain.then'));
  });

  test('the pre-warm goes through _speak, never straight at the plugin', () {
    // Calling `_tts.speak` directly would skip the audio-session discipline
    // every other utterance obeys, and inside the plugin that call activates
    // the session. Doing that raw at ride start is the shape of the 13 Jul
    // bench bug, where Travel Mode grabbed audio focus the moment it began.
    final warm = source.indexOf('Future<void> _preWarmTts()');
    final body = source.substring(warm, source.indexOf('\n  }', warm));
    expect(body, contains("_speak(' ')"));
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
