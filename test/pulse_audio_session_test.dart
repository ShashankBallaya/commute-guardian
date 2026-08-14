// THE 14 AUG 2026 RIDE: "Music plays ducked out once pulse starts... Music
// returns to normal state once TTS plays."
//
// That sentence names the mechanism on its own. Speech is the only path that
// has ever paired `setActive(true)` with a release, so an announcement was the
// only thing that ever gave the rider's music back. The chime ducked through
// its own AudioContext, and on iOS that context IS the app-wide shared
// AVAudioSession, so every 45 s the music went down and stayed down.
//
// The rule itself is tested for real in audio_session_idle_test.dart. What is
// left here is the wiring, and it can only be a SOURCE GUARD: the service
// cannot be constructed under the test binding.
//
// Written the way pressable_test.dart's guard had to be rewritten five times.
// Comments stripped first, \r stripped for the CRLF working tree, allMatches
// with a predicate rather than a bare `contains`, and a test below each one
// that proves it can still fail.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String serviceCode() => File('lib/services/geofence_chain_service.dart')
    .readAsStringSync()
    .replaceAll('\r\n', '\n')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// The body of the one method allowed to sound a chime.
String chimeHelperBody(String code) {
  final start = code.indexOf('Future<void> _chimeThroughSession(');
  expect(
    start,
    greaterThan(-1),
    reason: '_chimeThroughSession has been renamed or removed',
  );
  return code.substring(start, code.indexOf('\n  }', start));
}

/// Where a method stamps the interruption filter, and where it activates the
/// session, as offsets inside that method's own body.
///
/// ONE FUNCTION FOR BOTH THE GUARD AND ITS NEGATIVE TWIN, deliberately. The
/// first draft of these tests re-implemented the search inline against a
/// literal, so the twin proved nothing about the guard: the two could drift
/// apart and the twin would still pass. That is the sixth variation of the
/// same mistake in this repo, and the rule from the previous five is that a
/// "can still fail" test must run the REAL predicate.
({int stampAt, int activateAt}) stampOrderIn(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start, greaterThan(-1), reason: '$signature has moved or been renamed');
  final body = code.substring(start, code.indexOf('\n  }', start));
  return (
    stampAt: body.indexOf('noteOwnAudioStarted('),
    activateAt: body.indexOf('setActive(true)'),
  );
}

/// The body of the method that decides when the rider's music comes back.
String releaseMethodBody(String code) {
  final start = code.indexOf('Future<void> _releaseAudioSessionIfIdle(');
  expect(
    start,
    greaterThan(-1),
    reason: '_releaseAudioSessionIfIdle has been renamed or removed',
  );
  return code.substring(start, code.indexOf('\n  }', start));
}

void main() {
  group('the pulse chime hands the audio session back', () {
    test('EXACTLY ONE CALL TO chime() EXISTS IN THE SERVICE, and it is inside '
        '_chimeThroughSession', () {
      final code = serviceCode();
      final calls = RegExp(r'\.chime\(\)').allMatches(code).toList();

      expect(
        calls,
        hasLength(1),
        reason: 'every chime must go through the session helper; a raw '
            'output.chime() is the 14 Aug bug coming back',
      );

      final body = chimeHelperBody(code);
      expect(body, contains('.chime()'));
    });

    test('and that guard can still fail, on the exact code it replaced', () {
      // The three call sites as they stood before the fix: two in testPulse
      // and one in _handlePulseActions.
      const old = '''
      await output.chime();
      unawaited(output.chime());
      await output.chime();
''';
      expect(RegExp(r'\.chime\(\)').allMatches(old), hasLength(3));
    });

    // Activating the session can itself raise an audio interruption, and the
    // service feeds interruptions to the wake engine as "the rider took a
    // call". SelfAudioInterruptionFilter measures FORWARD from the stamp only,
    // so a stamp that lands after setActive is a stamp that did not happen.
    // That chain stood the ladder down on a sleeping rider on 21 Jul 2026.
    // _speakNow has always had this order. The chime helper was written on
    // 14 Aug 2026 with it backwards, and the clip path shipped backwards in
    // befaca4 the day before.
    for (final (name, signature) in [
      ('the pulse chime', 'Future<void> _chimeThroughSession('),
      ('the clip path', 'void _enqueueClip('),
      ('speech, which has always been right', 'Future<void> _speakNow('),
    ]) {
      test('THE STAMP COMES BEFORE setActive IN $name', () {
        final order = stampOrderIn(serviceCode(), signature);
        expect(
          order.stampAt,
          greaterThan(-1),
          reason: '$name never stamps at all',
        );
        expect(order.activateAt, greaterThan(-1), reason: '$name never asks '
            'for the session, so this guard is watching the wrong method');
        expect(
          order.stampAt,
          lessThan(order.activateAt),
          reason: 'the interruption window must open BEFORE the line that can '
              'raise an interruption',
        );
      });
    }

    test('AND THE ORDERING GUARD CAN STILL FAIL, on the exact code it '
        'replaced, through the same predicate the guard uses', () {
      // The order as _chimeThroughSession was first written on 14 Aug. The
      // stamp is PRESENT, so this proves the ORDERING assertion can fail and
      // not merely the presence one. The first draft of this twin used a
      // fixture with no stamp at all, which proved the wrong thing.
      const stampAfterActivate = '''
  Future<void> _chimeThroughSession(PulseOutput output) async {
    _pendingPulses++;
    try {
      await _session?.setActive(true);
      await output.chime();
      _selfInterruption.noteOwnAudioStarted(DateTime.now());
    } finally {
      _pendingPulses--;
    }
  }
''';
      final order = stampOrderIn(
        stampAfterActivate,
        'Future<void> _chimeThroughSession(',
      );
      expect(order.stampAt, greaterThan(-1), reason: 'the fixture must stamp, '
          'or it proves presence rather than order');
      expect(order.activateAt, greaterThan(-1));
      expect(order.stampAt, greaterThan(order.activateAt));
    });

    test('and it can fail the other way too, when nothing stamps', () {
      const noStamp = '''
  Future<void> _chimeThroughSession(PulseOutput output) async {
    await _session?.setActive(true);
    await output.chime();
  }
''';
      final order = stampOrderIn(
        noStamp,
        'Future<void> _chimeThroughSession(',
      );
      expect(order.stampAt, -1);
    });

    test('THE HELPER TAKES THE SESSION, COUNTS ITSELF, AND RELEASES', () {
      final body = chimeHelperBody(serviceCode());

      expect(
        body,
        contains('_pendingPulses++'),
        reason: 'without the counter the release cannot know it is safe',
      );
      expect(
        body,
        contains('setActive(true)'),
        reason: 'a release with no matching activation gives nothing back',
      );
      expect(
        body,
        contains('_pendingPulses--'),
        reason: 'a counter that only climbs wedges the session open for the '
            'rest of the ride',
      );
      expect(
        body,
        contains('_releaseAudioSessionIfIdle()'),
        reason: 'this is the line the rider actually hears',
      );
    });

    test('and THAT guard can still fail: a helper missing the release is '
        'caught', () {
      const broken = '''
  Future<void> _chimeThroughSession(PulseOutput output) async {
    _pendingPulses++;
    await _session?.setActive(true);
    await output.chime();
    _pendingPulses--;
  }
''';
      expect(chimeHelperBody(broken), isNot(contains('_releaseAudioSession')));
    });

    test('THE DECREMENT AND THE RELEASE ARE IN A finally, so a failed chime '
        'cannot wedge the music down for the rest of the ride', () {
      final body = chimeHelperBody(serviceCode());
      final finallyAt = body.indexOf('} finally {');
      expect(finallyAt, greaterThan(-1), reason: 'no finally block');
      final tail = body.substring(finallyAt);
      expect(tail, contains('_pendingPulses--'));
      expect(tail, contains('_releaseAudioSessionIfIdle()'));
    });

    test('THE IDLE RULE IS THE SHARED ONE, not a second copy written here', () {
      // SCOPED TO THE RELEASE METHOD, and the first draft of this test was not.
      // A whole-file search for the old condition matched `announcerBusy:
      // _pendingSpeaks > 0 || _pendingClips > 0`, which is a DIFFERENT rule
      // that must keep its own shape: "the app is talking" deliberately
      // excludes the pulse, because the least important sound this app makes
      // must never suppress anything. That is the fifth time in this repo a
      // guard has matched text that merely looked like the thing.
      expect(
        releaseMethodBody(serviceCode()),
        contains('audioSessionIsIdle('),
        reason: 'the rule lives in audio_session_idle.dart so it can have a '
            'real test; a hand-written condition here is untested by '
            'construction',
      );
    });

    test('and that guard can still fail, on the condition it replaced', () {
      const old = '''
  Future<void> _releaseAudioSessionIfIdle() async {
    if (_pendingSpeaks > 0 || _pendingClips > 0 || _wakeLadderLive) return;
    await _session?.setActive(false);
  }
''';
      expect(releaseMethodBody(old), isNot(contains('audioSessionIsIdle(')));
    });

    test('THE ANNOUNCER-BUSY RULE IS LEFT ALONE. The pulse is the least '
        'important sound this app makes and must never suppress anything', () {
      expect(
        serviceCode(),
        contains('announcerBusy: _pendingSpeaks > 0 || _pendingClips > 0'),
        reason: 'adding _pendingPulses here would let a chime suppress the '
            'next chime',
      );
    });
  });
}
