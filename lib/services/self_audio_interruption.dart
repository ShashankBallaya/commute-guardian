/// Tells a real interruption (the rider took a call) apart from one this app
/// inflicted on itself by playing a clip and speaking at the same moment.
///
/// Why this exists, from the bench on 21 Jul 2026: firing a station clip and a
/// wake check-in within ~200 ms of each other makes Android raise an audio
/// interruption, because our own clip contends with the session the TTS
/// activates. The service feeds every interruption into the wake engine as
/// "the rider is on a call, so they are awake" (locked decision 8), so the
/// ladder STOOD DOWN and the sleeping rider lost the alert entirely. It
/// reproduced 2 for 2 below 200 ms and never at 520 ms. The same signature
/// appeared in the field at Vasind on the 20 Jul ride.
///
/// The bias here is deliberate and asymmetric. Ignoring a genuine call costs
/// politeness: the ladder keeps climbing at someone who is awake, and they
/// acknowledge it. Believing our own audio is a call costs the rider their
/// stop. Decision 8 is untouched for real calls; this only refuses to be
/// fooled by our own noise.
class SelfAudioInterruptionFilter {
  SelfAudioInterruptionFilter({this.window = const Duration(seconds: 1)});

  /// How soon after our own audio starts an interruption is treated as ours.
  /// The observed collisions landed 144, 154 and 243 ms after our audio began,
  /// so a second carries real margin while staying far too short to swallow a
  /// call that merely happens to arrive during a long announcement.
  final Duration window;

  DateTime? _ownAudioStartedAt;

  /// Whether a sound of ours is playing RIGHT NOW, for as long as it lasts.
  ///
  /// The window above catches a collision at the moment two sounds start. It
  /// cannot catch the wake alarm, which is a LOOP: it holds the session for
  /// minutes, and iOS raised interruptions 1.9 s and 11.5 s into it on the
  /// 22 Jul ride, long past any sane window. Widening the window is the wrong
  /// answer, because it would start swallowing real calls; a looping tone is
  /// simply our own audio for its whole duration, so it gets a flag rather
  /// than a timer.
  bool _sustained = false;

  /// Call when a sound of ours starts and stops that lasts longer than an
  /// utterance: today that is the wake alarm loop.
  void setSustainedOwnAudio({required bool active}) {
    _sustained = active;
  }

  /// Whether the interruption currently in progress was judged to be ours.
  /// Kept so the matching "ended" event is dropped too: delivering a resume
  /// for an interruption the engine never heard begin would hand the wake
  /// engine a call that ended without ever having started.
  bool _ignoringCurrent = false;

  /// Call the instant this app starts making a sound of its own, whether a
  /// clip or an utterance.
  void noteOwnAudioStarted(DateTime now) {
    _ownAudioStartedAt = now;
  }

  /// Whether this interruption event should be withheld from the wake engine.
  bool shouldIgnore({required bool begin, required DateTime now}) {
    if (!begin) {
      // Only ever drop the end that matches a begin we dropped.
      final wasOurs = _ignoringCurrent;
      _ignoringCurrent = false;
      return wasOurs;
    }
    final startedAt = _ownAudioStartedAt;
    _ignoringCurrent = _sustained ||
        (startedAt != null && now.difference(startedAt) < window);
    return _ignoringCurrent;
  }
}
