import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:vibration/vibration.dart';

import 'self_audio_interruption.dart';

/// Pocket Pulse's hands: the chime player and, on Android, a short buzz.
///
/// Decides nothing, in the shape of [WakeAlertOutput]. The engine says when;
/// this makes the sound.
///
/// THE RANK IS THE DESIGN. The pulse is the least important sound this app
/// makes, sharing a session with the most important one. Everything here exists
/// to keep it from ever mattering more than that:
///
///   - It takes a TRANSIENT MAY-DUCK, the same shape an announcement's clip
///     takes, held for half a second. Never the alarm stream, never focus-free
///     piercing: that is the wake tone's rank (see wake_alert_output.dart,
///     which asks for NO focus so it cuts through everything), and the two must
///     never be confusable in a rider's ear.
///   - The duck itself is part of the signal. In a loud carriage a quiet chime
///     can be masked, but the dip in the rider's own music is felt anyway.
///   - ReleaseMode.release and a fresh player per chime. No loop mode goes
///     anywhere near this class. A pulse that could loop is the failure mode
///     the whole design is built to make impossible.
///
/// THE ONE INTEGRATION THAT IS INVISIBLE UNTIL IT BITES: every chime stamps
/// [SelfAudioInterruptionFilter]. Our own audio starting can raise an audio
/// interruption; the service feeds interruptions to the wake engine as "the
/// rider took a call, so they are awake"; and on 21 Jul 2026 that chain STOOD
/// THE LADDER DOWN on a sleeping rider (reproduced 2 for 2 under 200 ms). An
/// unstamped pulse reintroduces that bug at whatever interval the rider chose,
/// which is why the filter is a required constructor argument rather than an
/// optional courtesy: it cannot be forgotten at a call site.
class PulseOutput {
  PulseOutput({
    required this.log,
    required SelfAudioInterruptionFilter interruptionFilter,
    this.now = DateTime.now,
  }) : _interruption = interruptionFilter;

  final void Function(String message) log;
  final SelfAudioInterruptionFilter _interruption;

  /// Injected for the same reason every engine takes it: so a bench and a test
  /// can drive the collision window rather than wait for it.
  final DateTime Function() now;

  /// A navigation-prompt duck, not a media track and not an alarm.
  ///
  /// `sonification` rather than the clip path's `speech`: this is a tone, and
  /// the content type is what a system uses to decide how to treat it. The
  /// usage stays `assistanceNavigationGuidance` because that is what actually
  /// earns a transient duck from a music app on Android, which is the whole
  /// point.
  static final ap.AudioContext _duckContext = ap.AudioContext(
    android: const ap.AudioContextAndroid(
      isSpeakerphoneOn: false,
      audioMode: ap.AndroidAudioMode.normal,
      // False: a half-second chime must never hold a wakelock. The service
      // already owns the ride's wakefulness.
      stayAwake: false,
      contentType: ap.AndroidContentType.sonification,
      usageType: ap.AndroidUsageType.assistanceNavigationGuidance,
      audioFocus: ap.AndroidAudioFocus.gainTransientMayDuck,
    ),
    // NO mixWithOthers, matching the announcement session rather than the
    // alarm's: mixing would leave the rider's music at full volume and lose
    // the dip that carries the signal when the chime is masked.
    iOS: ap.AudioContextIOS(
      category: ap.AVAudioSessionCategory.playback,
      options: const {ap.AVAudioSessionOptions.duckOthers},
    ),
  );

  /// One chime. Fire and forget: a pulse that fails is a pulse that is missed,
  /// never a pulse that damages a ride.
  ///
  Future<void> chime() async {
    final player = ap.AudioPlayer();
    try {
      await player.setAudioContext(_duckContext);
      await player.setReleaseMode(ap.ReleaseMode.release);
      final completed = player.onPlayerComplete.first..ignore();
      // STAMPED BEFORE PLAY, not after. The interruption our own audio can
      // raise arrives within ~150 ms of the sound starting, and a stamp that
      // lands after it is a stamp that did not happen.
      _interruption.noteOwnAudioStarted(now());
      await player.play(ap.AssetSource('audio/pulse_chime.wav'));
      // The asset is 1.25 s. Three seconds is a generous ceiling that still
      // guarantees the player is released rather than left holding a duck on
      // the rider's music.
      await completed.timeout(const Duration(seconds: 3));
    } catch (error) {
      // Swallowed on purpose. A missed pulse is a missed reassurance; a thrown
      // pulse would poison whatever called it, and what calls it is the ride.
      log('PULSE chime failed: $error');
    } finally {
      unawaited(player.release());
    }
  }

  /// A short buzz, Android only.
  ///
  /// DELIBERATELY NOTHING LIKE THE WAKE PATTERN, which is a long triple
  /// (500-250-500-250-800). A wrist must never have to work out which of the
  /// two it just felt. One short tap says "still here"; the long insistent
  /// pattern says "get up".
  Future<void> buzz() async {
    if (!Platform.isAndroid) return;
    try {
      await Vibration.vibrate(duration: 100);
    } catch (error) {
      log('PULSE vibration failed: $error');
    }
  }
}
