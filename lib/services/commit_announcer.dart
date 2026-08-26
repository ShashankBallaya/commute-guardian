import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

import '../models/app_settings.dart';

/// Speaks the one line of the commit window, and nothing else, ever.
///
/// WHY THIS EXISTS AT ALL, AND WHY IT IS SO SMALL. Every other word this app
/// says is spoken by `GeofenceChainService` in the SERVICE isolate, through an
/// audio path that took two months and three ride bugs to get right. The commit
/// window happens BEFORE the service starts, because the whole point is that a
/// cancelled ride never starts one: no `ride_started`, no History row, no
/// in-flight flag. So there is no service to ask, and the UI isolate has never
/// had a voice.
///
/// THE INVARIANT THAT MAKES IT SAFE, and it is the only reason a second engine
/// is tolerable in this app: THIS UTTERANCE IS ALWAYS FINISHED BEFORE THE
/// SERVICE STARTS. The window waits for [speak] to settle before committing.
/// So the two engines are never live at once, and nothing ever reconfigures an
/// audio session under a live utterance, which is exactly what wedged the
/// iPhone announcer on 21 Aug 2026 and cost that ride its last nine minutes of
/// announcements.
///
/// IT NEVER STOPS AN UTTERANCE. Cancel lets this finish and simply does not
/// start the ride. iOS sends no `didCancel` for `tts.stop()`, so a stop is a
/// completion that never arrives, and a ride that waits for it waits forever.
///
/// IT CAN NEVER BLOCK A RIDE. [speak] is bounded. A TTS engine that goes quiet
/// costs the rider a silent window and nothing else: the ride still starts.
class CommitAnnouncer {
  CommitAnnouncer({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// How long the window will wait for the engine before giving up on it.
  ///
  /// The line runs about three seconds and Android's FIRST utterance of a ride
  /// pays a 500 to 900 ms cold start (16 Aug 2026 bench), which this one now
  /// is. Four seconds covers both with room, and caps the worst case: a rider
  /// whose engine never answers is armed a second late, not stranded.
  static const budget = Duration(seconds: 4);

  /// Speaks [line], and returns when the ENGINE says it has finished or when
  /// [budget] runs out, whichever comes first.
  ///
  /// Returns whether the engine reported completion, which is a log line and
  /// never a decision: nothing about starting a ride may depend on it.
  Future<bool> speak(String line, {required AppLanguage language}) async {
    try {
      await _tts.setLanguage(language.tag);
      // The same rate the ride speaks at, so the window does not sound like a
      // different app from the announcements that follow it.
      await _tts.setSpeechRate(0.45);
      await _tts.awaitSpeakCompletion(true);
      if (Platform.isIOS) {
        // DUCK, DO NOT SEIZE. The rider may be listening to something, and
        // this line is three seconds long. Deliberately NOT setSharedInstance:
        // that call also runs AVAudioSession.setActive(true) and grabs focus
        // for the whole app, which is the service's business and not this
        // one-shot's.
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
      await _tts.speak(line).timeout(budget);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      // No engine, no voice for this language, a test binding. All of them
      // mean the rider gets a silent window, and none of them may stop a ride.
      return false;
    }
  }
}
