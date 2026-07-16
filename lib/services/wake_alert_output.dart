import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

/// The wake ladder's hands: the alarm tone player and the vibration motor.
///
/// This is the audio plumbing the W1 spike proved on real hardware (Android
/// 9/12/16 and iPhone), kept verbatim when WakeEscalation replaced the
/// spike's throwaway ladder logic. It decides nothing; the engine says what
/// to do and this does it.
class WakeAlertOutput {
  WakeAlertOutput({required this.log});

  final void Function(String message) log;

  /// The tone rides the ALARM stream on Android (its own volume, separate
  /// from media) and the playback category on iOS (immune to the silent
  /// switch). It asks for NO audio focus: a focus grab would tangle with
  /// the TTS session's transient duck, and the tone is meant to pierce
  /// whatever else is playing, not politely replace it.
  static final AudioContext _alarmContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      audioMode: AndroidAudioMode.normal,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.none,
    ),
    // No mixWithOthers on iOS, twice deliberate (15 Jul iPhone bench): a
    // mixing session never becomes the Now Playing owner, so earphone taps
    // kept routing to the rider's music app instead of acking; and setting
    // it here REPLACED the announcement session's duckOthers, which is what
    // unducked the music mid-ladder. While a ladder is live the app owns
    // audio via the native seizure in AppDelegate.
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {},
    ),
  );

  final AudioPlayer _player = AudioPlayer();

  /// Makes sure the looping tone is playing at [volume]. The loop can be
  /// killed under us: on iOS anything that deactivates the app's shared
  /// audio session (an interruption, a sibling releasing it) stops every
  /// player in the app, and raising the volume of a stopped player is
  /// silence. So this restarts the tone whenever it is not actually
  /// playing; called on every engine Tone action AND on every service tick
  /// while a ladder is live (the watchdog for the 15 Jul iOS tone gap).
  Future<void> ensureToneAt(double volume) async {
    if (_player.state == PlayerState.playing) {
      try {
        await _player.setVolume(volume);
      } catch (error) {
        log('WAKE tone volume change failed: $error');
      }
      return;
    }
    try {
      await _player.setAudioContext(_alarmContext);
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(volume);
      await _player.play(AssetSource('audio/wake_alarm.wav'));
      log('WAKE tone playing at ${volume.toStringAsFixed(1)}.');
    } catch (error) {
      // The ladder keeps climbing without the tone: TTS and vibration still
      // escalate, and the log shows exactly what needs fixing.
      log('WAKE tone failed to start: $error');
    }
  }

  Future<void> stopTone() async {
    try {
      await _player.stop();
    } catch (error) {
      log('WAKE tone failed to stop: $error');
    }
  }

  Future<void> vibrate() async {
    // Haptics are an Android-only bonus layer (iOS forbids them in
    // background); audio is the primary channel on both platforms.
    if (!Platform.isAndroid) return;
    try {
      await Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 800]);
    } catch (error) {
      log('WAKE vibration failed: $error');
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
