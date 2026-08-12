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
  WakeAlertOutput({required this.log, this.onIosToneCommand, this.onIosVibrate});

  final void Function(String message) log;

  /// iOS only: forwards a tone command toward the native player in
  /// AppDelegate ('startTone' with a volume, or 'stopTone'). audioplayers'
  /// ReleaseMode.loop never actually looped under the seized iOS session
  /// (IPA #18: the 5 s wav died each cycle, the watchdog restarted it with
  /// an audible gap, and the silent moments are the lead suspect for the
  /// 18 Jul lost earphone ack), so on iOS the tone is played natively by
  /// AVAudioPlayer inside the session AppDelegate already owns. The
  /// command travels service isolate -> sendDataToMain -> main.dart ->
  /// media_ack channel, the same proven hop the session seizure rides.
  final void Function(String command, double volume)? onIosToneCommand;

  /// iOS only: fires ONE system vibration natively (AudioServicesPlaySystemSound
  /// with kSystemSoundID_Vibrate), through the same service isolate ->
  /// sendDataToMain -> media_ack hop the tone command uses. Null off iOS, and
  /// null on iOS until the shell wires it, which is the real platform gate:
  /// this class never asks what platform it is on for vibration, it asks
  /// whether it was given hands.
  ///
  /// Licensed by `docs/adr/0003` (12 Aug 2026). CLAUDE.md had locked "iOS
  /// forbids background haptics", which was true of CHHapticEngine and
  /// UIFeedbackGenerator and never applied to this call. Measured 7 of 7 from a
  /// locked, pocketed iPhone at 45.0 s (log 559de451).
  final void Function()? onIosVibrate;

  /// The last volume sent natively, so the every-tick self-heal resend
  /// does not spam the ride log.
  double? _sentIosVolume;

  /// Bumped by every new burst AND by every cancel, so an in-flight burst
  /// that wakes up from its gap finds its own number stale and stops. A
  /// counter rather than a Timer because the burst must die on ANY path that
  /// silences the ladder, and the ack is the one that matters: a burst that
  /// outlives the ack buzzes at a rider who already said they are awake.
  int _burst = 0;

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

  /// LAZY, and it is not a micro-optimisation. On iOS the tone is played
  /// natively inside the session AppDelegate owns, so this player is never
  /// touched there at all, and an unused AudioPlayer is a plugin channel and
  /// a native player object created for nothing on every ride. It also makes
  /// the vibration burst testable off-device: a test that never plays a tone
  /// never constructs one.
  AudioPlayer? _playerOrNull;
  AudioPlayer get _player => _playerOrNull ??= AudioPlayer();

  /// Makes sure the looping tone is playing at [volume]. The loop can be
  /// killed under us: on iOS anything that deactivates the app's shared
  /// audio session (an interruption, a sibling releasing it) stops every
  /// player in the app, and raising the volume of a stopped player is
  /// silence. So this restarts the tone whenever it is not actually
  /// playing; called on every engine Tone action AND on every service tick
  /// while a ladder is live (the watchdog for the 15 Jul iOS tone gap).
  Future<void> ensureToneAt(double volume) async {
    final iosTone = onIosToneCommand;
    // `!Platform.isAndroid`, not `Platform.isIOS`, and it is the same lesson
    // as the Settings vibration row: state the constraint you have. Android
    // is where audioplayers owns the tone; the native command is where it
    // does not. The two are identical on the two platforms this app ships to
    // and differ on the test host, which is neither, so the allow-list form
    // dragged an AudioPlayer into every test that so much as stopped a tone.
    if (!Platform.isAndroid && iosTone != null) {
      // Sent on every call on purpose: the native side treats a repeat as
      // a volume set when playing and a restart when an interruption
      // killed the player, which is the whole watchdog collapsed into one
      // idempotent message.
      iosTone('startTone', volume);
      if (_sentIosVolume != volume) {
        _sentIosVolume = volume;
        log('WAKE tone (native) at ${volume.toStringAsFixed(1)}.');
      }
      return;
    }
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
    // The burst dies with the tone, in the same call, so nothing outside this
    // class has to remember to cancel it. Every path that silences a live
    // ladder (the ack, a HardStop at the ceiling, a call suspending it) goes
    // through StopTone, so this one line covers all three.
    cancelVibration();
    final iosTone = onIosToneCommand;
    // `!Platform.isAndroid`, not `Platform.isIOS`, and it is the same lesson
    // as the Settings vibration row: state the constraint you have. Android
    // is where audioplayers owns the tone; the native command is where it
    // does not. The two are identical on the two platforms this app ships to
    // and differ on the test host, which is neither, so the allow-list form
    // dragged an AudioPlayer into every test that so much as stopped a tone.
    if (!Platform.isAndroid && iosTone != null) {
      _sentIosVolume = null;
      iosTone('stopTone', 0);
      return;
    }
    try {
      await _player.stop();
    } catch (error) {
      log('WAKE tone failed to stop: $error');
    }
  }

  /// How many buzzes an iOS burst fires, and how far apart.
  ///
  /// THE PLATFORMS CANNOT MATCH AND MUST NOT TRY. Android sends one insistent
  /// pattern and controls every millisecond of it. iOS has exactly one fixed
  /// buzz, no duration and no intensity (`docs/adr/0003`), so the only axes
  /// left there are COUNT and CADENCE. The burst is deliberately nothing like
  /// Pocket Pulse's single tap followed by 45 s of silence: a pocket must never
  /// have to work out which of the two it just felt.
  ///
  /// THE GAP WAS 400 ms AND THE OWNER FELT TWO BUZZES, NOT THREE (12 Aug 2026,
  /// log `20260812T152247`, three bursts at rungs 2, 3 and 4, two sensations
  /// each). `kSystemSoundID_Vibrate` is a fixed buzz of roughly 400 ms, so the
  /// second request was arriving while the motor still ran and iOS either
  /// dropped it or ran the two together. 800 ms leaves the motor time to stop
  /// between buzzes, which is what makes three of them countable.
  ///
  /// This is the axis that carries the whole alarm on an iPhone, so it is
  /// tuned against a leg rather than against a number. Re-bench after any
  /// change: the log records what was REQUESTED and only the owner can say
  /// what was FELT.
  static const iosBurstCount = 3;
  static const iosBurstGap = Duration(milliseconds: 800);

  /// One insistent vibration, on both platforms now.
  ///
  /// Audio remains the PRIMARY channel and this is a second one. It is worth
  /// more on iOS than the count suggests: an iPhone in a pocket with the media
  /// volume at zero (11 Aug 2026) has no other way to be felt at all.
  Future<void> vibrate() async {
    if (Platform.isAndroid) {
      try {
        await Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 800]);
      } catch (error) {
        log('WAKE vibration failed: $error');
      }
      return;
    }
    final buzz = onIosVibrate;
    if (buzz == null) return;
    final mine = ++_burst;
    // LOGGED, because the 12 Aug bench could not be read from its own ride log.
    // Three bursts fired that evening and the log said nothing about any of
    // them, so "he felt two" could not be checked against what was asked for.
    // PulseOutput.buzz has always logged its attempts and this never did.
    //
    // It records the REQUEST and never a felt buzz, which is the same rule the
    // pulse flag follows: the phone cannot tell us what reached a pocket. A
    // count that ends early is a cancel, and that is the line to look for when
    // the ack is being judged.
    var sent = 0;
    for (var i = 0; i < iosBurstCount; i++) {
      // A cancel that lands during a gap stops every buzz still to come. A
      // cancel that lands BEFORE this call does not suppress it, because the
      // burst takes its own number on the way in, and that is correct: a
      // cancel answers the burst that is sounding, and a rider who acks one
      // ladder must still get the whole alarm at the next critical station.
      if (_burst != mine) {
        log('WAKE buzz burst cancelled after $sent of $iosBurstCount.');
        return;
      }
      buzz();
      sent++;
      if (i < iosBurstCount - 1) await Future<void>.delayed(iosBurstGap);
    }
    log('WAKE buzz burst requested: $sent at ${iosBurstGap.inMilliseconds}ms.');
  }

  /// Stops an iOS burst that is still mid-flight. A no-op on Android, where
  /// the pattern is handed to the platform in one call and is over in 2.8 s.
  void cancelVibration() => _burst++;

  Future<void> dispose() async {
    // Through the nullable field, so disposing a ride that never played a
    // tone does not construct a player in order to throw it away.
    await _playerOrNull?.dispose();
  }
}
