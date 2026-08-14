// THE SAME BUG, THREE TIMES, AND THIS IS THE THIRD.
//
// On iOS the audio context IS the app-wide shared AVAudioSession. A sound that
// activates it with duckOthers and never hands it back leaves the rider's music
// quiet until something else happens to release it.
//
//   13 Aug ride: CLIPS never touched the session. Music ducked at the first
//                clip and stayed down for the whole journey (fixed, befaca4).
//   14 Aug ride: THE PULSE CHIME never touched it either. "Music plays ducked
//                out once pulse starts... music returns to normal state once
//                TTS plays", which names the mechanism exactly: speech is the
//                only path that has ever paired setActive(true) with a release.
//
// The rule that decides when the session may go back is the one thing all three
// sounds share, so it lives here as a pure function with a real test, rather
// than inside a service that cannot be built under the test binding.

import 'package:commute_guardian/services/audio_session_idle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('audioSessionIsIdle', () {
    test('nothing of ours is sounding, so the session goes back', () {
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 0,
          pendingClips: 0,
          pendingPulses: 0,
          wakeLadderLive: false,
        ),
        isTrue,
      );
    });

    test('THE 14 AUG BUG: a pulse chime in flight holds the session', () {
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 0,
          pendingClips: 0,
          pendingPulses: 1,
          wakeLadderLive: false,
        ),
        isFalse,
      );
    });

    test('a speech in flight holds the session', () {
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 1,
          pendingClips: 0,
          pendingPulses: 0,
          wakeLadderLive: false,
        ),
        isFalse,
      );
    });

    test('a clip in flight holds the session', () {
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 0,
          pendingClips: 1,
          pendingPulses: 0,
          wakeLadderLive: false,
        ),
        isFalse,
      );
    });

    test(
      'A LIVE WAKE LADDER HOLDS IT EVEN WITH EVERY COUNTER AT ZERO. '
      'Deactivating here is what silenced the looping alarm tone the moment '
      "rung 1's speech finished, on the 15 Jul iPhone bench",
      () {
        expect(
          audioSessionIsIdle(
            pendingSpeaks: 0,
            pendingClips: 0,
            pendingPulses: 0,
            wakeLadderLive: true,
          ),
          isFalse,
        );
      },
    );

    test('a pulse that overlaps speech still holds it after the speech '
        'finishes', () {
      // The ordinary shape of a crowd-mode ride: chimes every 45 s against
      // announcements that arrive whenever a station does. Whichever ends
      // first must not pull the session out from under the other.
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 0,
          pendingClips: 0,
          pendingPulses: 1,
          wakeLadderLive: false,
        ),
        isFalse,
      );
      expect(
        audioSessionIsIdle(
          pendingSpeaks: 1,
          pendingClips: 0,
          pendingPulses: 0,
          wakeLadderLive: false,
        ),
        isFalse,
      );
    });
  });
}
