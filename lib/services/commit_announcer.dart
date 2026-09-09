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
/// is tolerable in this app: THIS UTTERANCE IS FINISHED BEFORE THE SERVICE
/// STARTS. The window waits for [speak] to settle before committing. So the
/// two engines are not live at once, and nothing reconfigures an audio session
/// under a live utterance, which is exactly what wedged the iPhone announcer
/// on 21 Aug 2026 and cost that ride its last nine minutes of announcements.
///
/// AND IT HAS EXACTLY ONE HOLE, WHICH THIS PARAGRAPH USED TO DENY. [speak]
/// settles when the engine finishes OR when [budget] runs out, and a timeout
/// is not a silence: the utterance carries on, because nothing here stops one.
/// So a [speak] that overruns commits the ride underneath a voice that is
/// still talking. That is not theory. On the 3T on 9 Sep 2026 a recents tap to
/// Dadar Western did it, and the Sarvam welcome played over the route line.
///
/// TWO THINGS KEEP THAT HOLE SHUT, and neither is a promise made in a comment.
/// [warmUp], fired from Screen 1, removes the cold start that was most of the
/// overrun. [budget], now six seconds, covers a phone slower than the 3T. The
/// hole cannot be closed by construction while stopping an utterance is
/// forbidden, so it is bounded instead, and the cost of hitting it is two
/// voices for a second rather than a wedged session.
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
  /// is.
  ///
  /// SIX SECONDS SINCE 9 SEP 2026, AND FOUR WAS MEASURABLY TOO FEW. On the 3T,
  /// a recents tap to Dadar Western spoke the route and then the Sarvam
  /// welcome played ON TOP of it. Cold start plus a route line carrying two
  /// long station names crossed four seconds, [speak] returned on its timeout
  /// while the engine was still talking, and the window committed underneath a
  /// live utterance. The second tap was clean because the engine was warm.
  ///
  /// THE TIMEOUT IS A BELT, NOT THE FIX. A budget can only ever bound the
  /// damage: it cannot make a cold engine fast, and it cannot silence an
  /// utterance it has stopped waiting for (see the class doc: nothing here
  /// ever stops one). The fix is [warmUp], fired from Screen 1 long before any
  /// tap. This number exists for the phone that is slower than the 3T.
  ///
  /// RAISING IT COSTS A RIDER NOTHING UNLESS THE ENGINE IS DEAD, and then it
  /// costs two extra seconds before the ride arms. Being armed two seconds
  /// late is not a failure. Being armed under a voice that is still speaking
  /// is the one this replaces.
  static const budget = Duration(seconds: 6);

  /// Loads the engine now, silently, so the window does not pay for it later.
  ///
  /// THE ASYMMETRY THIS CLOSES. The ride announcer in the service isolate has
  /// pre-warmed since Phase 1 (`GeofenceChainService._preWarmTts`). This
  /// engine, in the UI isolate, never did, so the FIRST commit window of every
  /// app launch paid a 500 to 900 ms cold start that no later window paid.
  /// On the 3T on 9 Sep 2026 that was the difference between a clean window
  /// and the Sarvam welcome talking over a live utterance.
  ///
  /// FIRED FROM SCREEN 1, NOT FROM THE WINDOW, and that placement is the whole
  /// point. The service's own comment says it better than this one can: firing
  /// a warm-up next to the thing it is meant to speed up buys nothing. Screen 1
  /// is seconds of the rider reading, before any tap exists to be sped up.
  ///
  /// VOLUME ZERO AROUND THE UTTERANCE, because an engine only loads when it is
  /// asked to speak, and a rider opening the app must not hear it do so. The
  /// restore is awaited on the same chain, so a window that follows can never
  /// find the volume still down: speaking the route at zero would be a silent
  /// confirmation, which is worse than a late one.
  ///
  /// IT CAN NEVER COST A RIDE. It runs nowhere near a decision, returns
  /// nothing anyone reads, and swallows everything: no engine, no voice data,
  /// a test binding. The rider simply gets the cold start back.
  Future<void> warmUp() async {
    try {
      await _tts.setVolume(0);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(' ').timeout(budget);
    } catch (_) {
      // Deliberately empty. See above: nothing here is worth a ride.
    }
    try {
      await _tts.setVolume(1);
    } catch (_) {
      // Same, and this one matters more: a volume left at zero would silence
      // the window this method exists to help. A throwing engine has no
      // volume to leave down.
    }
  }

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
