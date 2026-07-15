import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

/// Slice W1 platform spike for the wake escalation.
///
/// Proves the two feature-killers on real hardware before the real engine
/// exists: an alarm tone delivered as ACTIVE PLAYBACK (Android ALARM stream,
/// iOS playback category, so the silent switch, DND and a zeroed media slider
/// cannot silence it), and standing down from a media-remote tap. The ladder
/// LOGIC here is deliberately throwaway; WakeEscalation (slice W2) replaces it
/// with the pure, tested engine. The audio plumbing is the keeper.
class WakeAlertSpike {
  WakeAlertSpike({
    required this.speak,
    required this.log,
    required this.onLiveChanged,
  });

  /// Speaks through the service's serialized TTS chain, so ladder speech and
  /// station announcements never talk over each other.
  final Future<void> Function(String text) speak;

  final void Function(String message) log;

  /// Fires when the ladder starts or stands down. The UI uses it to show the
  /// manual "I'm awake" button and to activate (then release) the native media
  /// session that routes earphone taps to us.
  final void Function(bool live) onLiveChanged;

  // Ladder timings from the locked design, named so bench tuning is one edit.
  static const checkInToFirstRung = Duration(seconds: 25);
  static const rungInterval = Duration(seconds: 15);

  /// Tone volume per rung; past the last entry the ladder repeats at full.
  static const rungVolumes = [0.3, 0.6, 1.0];

  /// Bench safety net. The spike has no station ceiling (that is W2's job),
  /// so a forgotten test must not blast until the battery dies.
  static const spikeTimeout = Duration(minutes: 2);

  /// The tone rides the ALARM stream on Android (its own volume, separate
  /// from media) and the playback category on iOS (immune to the silent
  /// switch). It asks for NO audio focus: a focus grab would tangle with the
  /// TTS session's transient duck, and the tone is meant to pierce whatever
  /// else is playing, not politely replace it.
  static final AudioContext _alarmContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      audioMode: AndroidAudioMode.normal,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  final AudioPlayer _player = AudioPlayer();
  Timer? _rungTimer;
  Timer? _timeoutTimer;
  int _rung = 0;
  bool _live = false;

  Future<void> start() async {
    if (_live) {
      log('WAKE test ignored: a ladder is already live.');
      return;
    }
    _live = true;
    _rung = 0;
    onLiveChanged(true);
    log('WAKE check-in: asking for acknowledgment.');
    unawaited(
      speak(
        'Wake alert test. Your stop is next. '
        'Tap your earphones, or press the I am awake button.',
      ),
    );
    _rungTimer = Timer(checkInToFirstRung, _nextRung);
    _timeoutTimer = Timer(spikeTimeout, () {
      log('WAKE spike timed out with no acknowledgment, standing down.');
      _standDown();
    });
  }

  /// Any acknowledgment (earphone tap forwarded from the UI isolate, or the
  /// on-screen button) stands the whole ladder down, whatever rung it is on.
  void acknowledge() {
    if (!_live) {
      log('WAKE ack received but no ladder is live.');
      return;
    }
    log('WAKE acknowledged at rung $_rung, standing down.');
    _standDown();
    unawaited(speak('Good, you are awake.'));
  }

  Future<void> dispose() async {
    // A ride stopped mid-ladder must still release the UI's media session.
    if (_live) {
      _standDown();
    }
    _timeoutTimer?.cancel();
    await _player.dispose();
  }

  void _nextRung() {
    if (!_live) return;
    _rung++;
    final volume = _rung <= rungVolumes.length
        ? rungVolumes[_rung - 1]
        : rungVolumes.last;
    log(
      'WAKE rung $_rung: tone volume ${volume.toStringAsFixed(1)}'
      '${_rung >= 2 ? ' plus vibration' : ''}',
    );
    if (_rung == 1) {
      unawaited(_startTone(volume));
      unawaited(speak('Wake up. Your stop is next.'));
    } else {
      unawaited(_ensureToneAt(volume));
      unawaited(_vibrate());
    }
    _rungTimer = Timer(rungInterval, _nextRung);
  }

  void _standDown() {
    _rungTimer?.cancel();
    _timeoutTimer?.cancel();
    _live = false;
    unawaited(_stopTone());
    onLiveChanged(false);
  }

  Future<void> _startTone(double volume) async {
    try {
      await _player.setAudioContext(_alarmContext);
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(volume);
      await _player.play(AssetSource('audio/wake_alarm.wav'));
    } catch (error) {
      // The ladder keeps climbing without the tone: TTS and vibration still
      // escalate, and the log shows exactly what the bench needs fixed.
      log('WAKE tone failed to start: $error');
    }
  }

  /// Later rungs normally just turn the loop up, but the loop can be killed
  /// under us: on iOS anything that deactivates the app's shared audio
  /// session (an interruption, a sibling releasing it) stops every player in
  /// the app. Raising the volume of a stopped player is silence, so restart
  /// the tone instead.
  Future<void> _ensureToneAt(double volume) async {
    if (_player.state == PlayerState.playing) {
      await _setToneVolume(volume);
      return;
    }
    log('WAKE tone was not playing at rung $_rung, restarting it.');
    await _startTone(volume);
  }

  Future<void> _setToneVolume(double volume) async {
    try {
      await _player.setVolume(volume);
    } catch (error) {
      log('WAKE tone volume change failed: $error');
    }
  }

  Future<void> _stopTone() async {
    try {
      await _player.stop();
    } catch (error) {
      log('WAKE tone failed to stop: $error');
    }
  }

  Future<void> _vibrate() async {
    // Haptics are an Android-only bonus layer (iOS forbids them in
    // background); audio is the primary channel on both platforms.
    if (!Platform.isAndroid) return;
    try {
      await Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 800]);
    } catch (error) {
      log('WAKE vibration failed: $error');
    }
  }
}
