import 'package:audioplayers/audioplayers.dart' as ap;

/// The iOS session shape EVERY sound this app makes must ask for.
///
/// ONE PLACE BECAUSE THERE ARE THREE CALLERS AND THEY DRIFTED. The app
/// configures the shared AVAudioSession once, through `audio_session`, as
/// `speech()` with `duckOthers | mixWithOthers` and mode `voicePrompt`. That is
/// correct and it ducks. Then every audioplayers `setAudioContext` call
/// OVERWRITES the category and options on that same shared session, and the two
/// audioplayers contexts each asked for something different:
///
///   clip context   android block only  ->  iOS defaults to playback, options {}
///   chime context  playback, {duckOthers}
///
/// Neither carried `mixWithOthers`, and on iOS `playback` without it is
/// EXCLUSIVE: other audio is INTERRUPTED, not ducked. `duckOthers` alone does
/// not mix. So the rider's music stopped and restarted around every clip and
/// every chime instead of dipping under them.
///
/// MEASURED, NOT REASONED, 14 Aug 2026. Two earlier explanations for this were
/// wrong. What settled it was the owner pressing Announce and then waiting for
/// a chime, with music playing, and reporting that BOTH paused and resumed. If
/// only one had, the cause would have been inside that one path; both means it
/// is the shape they share.
///
/// `duckOthers` is what produces the dip. `mixWithOthers` only stops us
/// claiming the session exclusively, so it costs nothing and is what makes a
/// dip a dip.
final ap.AudioContextIOS duckingIosContext = ap.AudioContextIOS(
  category: ap.AVAudioSessionCategory.playback,
  options: const {
    ap.AVAudioSessionOptions.duckOthers,
    ap.AVAudioSessionOptions.mixWithOthers,
  },
);
