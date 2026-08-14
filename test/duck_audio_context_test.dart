// EVERY SOUND THIS APP MAKES DUCKS THE RIDER'S MUSIC. None of them stops it.
//
// On iOS the audioplayers AudioContext overwrites the category and options on
// the app-wide shared AVAudioSession, so whatever the app configured through
// audio_session at Start is replaced by whichever sound played last. Two of the
// three contexts asked for something exclusive:
//
//   clip context   android block only  ->  audioplayers substitutes
//                                          AudioContextIOS(), which is
//                                          `playback` with NO options
//   chime context  playback, {duckOthers}
//
// `playback` without `mixWithOthers` is EXCLUSIVE on iOS. Other audio is
// INTERRUPTED, not ducked. The rider's music stopped and restarted around every
// clip and every chime.
//
// MEASURED, NOT REASONED, 14 Aug 2026, and two earlier explanations were wrong
// before this one. What settled it was the owner pressing Announce and then
// waiting for a chime, with music playing, and reporting that BOTH paused and
// resumed. Both means the fault is the shape they share.

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/services/duck_audio_context.dart';

void main() {
  group('the shared ducking context', () {
    test('CARRIES mixWithOthers. Without it iOS interrupts rather than '
        'ducks, which is the whole bug', () {
      expect(
        duckingIosContext.options,
        contains(ap.AVAudioSessionOptions.mixWithOthers),
      );
    });

    test('CARRIES duckOthers, which is what actually produces the dip', () {
      expect(
        duckingIosContext.options,
        contains(ap.AVAudioSessionOptions.duckOthers),
      );
    });

    test('uses playback, so the Ring/Silent switch cannot mute an '
        'announcement', () {
      expect(duckingIosContext.category, ap.AVAudioSessionCategory.playback);
    });

    test('DOES NOT ASK FOR EXCLUSIVITY BY ANY OTHER ROUTE', () {
      // interruptSpokenAudioAndMixWithOthers pauses podcasts outright, which is
      // the same fault wearing a different name.
      expect(
        duckingIosContext.options,
        isNot(
          contains(
            ap.AVAudioSessionOptions.interruptSpokenAudioAndMixWithOthers,
          ),
        ),
      );
    });

    test('AND THE GUARD CAN STILL FAIL, on each of the two shapes that '
        'shipped', () {
      // The clip context's effective iOS value: an omitted block is NOT
      // "leave the session alone", it is this.
      final omitted = ap.AudioContextIOS();
      expect(
        omitted.options,
        isNot(contains(ap.AVAudioSessionOptions.mixWithOthers)),
        reason: 'if audioplayers ever defaults to mixing, the clip fix is '
            'redundant and this test says so',
      );

      // The chime context as it stood before 14 Aug 2026.
      final duckOnly = ap.AudioContextIOS(
        category: ap.AVAudioSessionCategory.playback,
        options: const {ap.AVAudioSessionOptions.duckOthers},
      );
      expect(
        duckOnly.options,
        isNot(contains(ap.AVAudioSessionOptions.mixWithOthers)),
      );
    });
  });
}
