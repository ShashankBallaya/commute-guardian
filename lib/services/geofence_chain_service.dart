import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geofencing_api/geofencing_api.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/station_repository.dart';
import '../models/journey.dart';
import '../models/station.dart';
import 'announcement_templates.dart';
import 'clip_library.dart';
import 'ride_progress.dart';
import 'self_audio_interruption.dart';
import 'wake_alert_output.dart';
import 'wake_escalation.dart';
import 'wind_down.dart';

/// Runs one ride, between any two stations on the network.
///
/// Given the rider's origin and destination, [JourneyPlanner] works out the
/// chain, the interchanges and the overshoot pin; this registers a geofence per
/// station on that chain (plus a second, larger outer approach fence for each
/// interchange and the destination), speaks an announcement as the ride passes
/// each one, and logs every event so accuracy can be judged from a real ride.
///
/// Registration is with geofence_service's DART engine: the plugin subscribes
/// to the fl_location stream and does per-fix distance math, it never creates
/// an OS-level region (verified in plugin source 6.0.0, 19 Jul 2026). Two
/// facts follow. There is no iOS 20-region cap, so long chains need no fence
/// windowing; and the "(native)" tag these logs put on ENTER events only
/// distinguishes the plugin's fence-crossing engine from the RideProgress
/// chain backstop, both of which starve together when the fix stream dies.
class GeofenceChainService {
  GeofenceChainService({
    required this.onLog,
    this.onDestinationReached,
    this.onRawFix,
    this.onWakeLadderLive,
    this.onWindDownLive,
    this.onAutoOff,
    this.onIosToneCommand,
    this.sarvamGreeting = false,
    this.sarvamClips = false,
  });

  /// Debug-only flag (owner decision 17 Jul, slice 2 of the clip feature):
  /// station announcements play as full-phrase Sarvam clips when the pushed
  /// pack has the file, device TTS otherwise. Android only, like the
  /// greeting slice; see ClipLibrary for the delivery and matching rules.
  final bool sarvamClips;

  /// Debug-only bench flag (17 Jul 2026): play the bundled Sarvam greeting
  /// clip at Start instead of TTS speaking "Welcome to Commute Guardian",
  /// the first taste of the clip pack feature. Android only; iOS keeps the
  /// full TTS welcome untouched (its shared-session rules get their own
  /// slice). Off by default so the Start path stays byte-identical to the
  /// benched behavior unless the debug toggle turns it on.
  final bool sarvamGreeting;

  /// Marks the outer approach fence for a two-stage station, keeping its
  /// region id distinct from the inner station fence.
  static const _approachSuffix = '#approach';

  final void Function(String message) onLog;

  /// Fires once, when the ride announces arrival at its destination. The UI's
  /// turnaround default (next origin = this ride's destination) must not trust
  /// a ride that never got there: a bench Start/Stop at home planted Kalyan as
  /// the origin while the rider stood near Shahad (13 Jul).
  final void Function()? onDestinationReached;

  /// Every raw fix, as received. The UI keeps the latest one so that at ride
  /// end it can name the rider's position instantly instead of waking the GPS
  /// cold, which indoors can hang past any patience (13 Jul bench: blank
  /// origin under a stale chip).
  final void Function(fl.Location location)? onRawFix;

  /// Fires when the wake ladder starts or stands down. The UI listens so it
  /// can show its manual "I'm awake" button and hold the native media session
  /// (the thing that routes an earphone tap to us) only while a ladder is
  /// actually asking to be acknowledged.
  final void Function(bool live)? onWakeLadderLive;

  /// Fires when the post-arrival auto-off countdown starts or stops. The
  /// handler mirrors it into the notification's [End now] and [Extend 10
  /// min] buttons and the debug screen's equivalents.
  final void Function(bool live)? onWindDownLive;

  /// The auto-off countdown expired (or [End now] was pressed): the ride is
  /// over and the whole service should tear itself down. Owned by the
  /// handler because only it may stop the foreground service.
  final void Function()? onAutoOff;

  /// iOS only: carries a ladder tone command ('startTone'/'stopTone') toward
  /// the native AVAudioPlayer in AppDelegate, over the same
  /// service -> main -> media_ack hop the session seizure uses. See
  /// WakeAlertOutput.onIosToneCommand for why the tone left audioplayers.
  final void Function(String command, double volume)? onIosToneCommand;

  Journey? _journey;

  final FlutterTts _tts = FlutterTts();
  RideProgress? _rideProgress;
  WakeEscalation? _wakeEscalation;
  WakeAlertOutput? _wakeOutput;
  WindDown? _windDown;
  bool _windDownLive = false;

  /// The volume of the last engine Tone action, while a ladder is live.
  /// The tick watchdog re-asserts the tone at this volume every 5 seconds,
  /// which caps the 15 Jul iOS tone gap (TTS killing the loop between
  /// rungs) at one tick instead of a whole rung interval.
  double? _wakeToneVolume;

  /// Bench safety for the debug wake test only: with no train, the ceiling
  /// station never arrives, so after this deadline the test synthesizes it
  /// through the REAL engine path. Real ladders have the real ceiling.
  DateTime? _wakeTestCeilingAt;
  Station? _wakeTestCeiling;
  static const _wakeTestTimeout = Duration(minutes: 2, seconds: 30);
  File? _logFile;
  StreamSubscription<fl.Location>? _rawLocationSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  AudioSession? _session;

  /// Keeps the wake engine from mistaking this app's own audio for the rider
  /// taking a call. See [SelfAudioInterruptionFilter] for the bench evidence.
  final _selfInterruption = SelfAudioInterruptionFilter();

  /// Serializes announcements so two never overlap, and so the ducking window
  /// spans a whole run of them (see [_speak]).
  Future<void> _speaking = Future<void>.value();
  int _pendingSpeaks = 0;

  /// The pushed Sarvam clip pack, or null when clips are off or absent.
  ClipLibrary? _clips;

  /// Serializes clip playback the way [_speaking] serializes TTS: a burst of
  /// catch-up announcements (passed + arrival on one gap-end fix) must play
  /// one clip after another, not on top of each other. A TTS line landing in
  /// the middle of a burst is chained here too, so it starts only after the
  /// clips before it finished; the reverse race (a clip starting while an
  /// earlier TTS line still speaks) is accepted for this slice because
  /// Android TTS gives no completion to await mid-ride (QUEUE_ADD).
  Future<void> _clipChain = Future<void>.value();

  /// Mirrors the spike's live state so [_speak] knows not to release the
  /// shared audio session while the alarm tone is looping.
  bool _wakeLadderLive = false;

  Future<void> start({
    required String originId,
    required String destinationId,
  }) async {
    _logFile = await _createLogFile();

    final locationAlways = await Permission.locationAlways.status;
    final ignoringBatteryOpt =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    _log(
      'Permission state at start: locationAlways=$locationAlways, '
      'ignoringBatteryOptimizations=$ignoringBatteryOpt',
    );

    final repo = await StationRepository.load();
    final Journey journey;
    try {
      journey = repo.planner.plan(
        originId: originId,
        destinationId: destinationId,
      );
    } catch (error) {
      // The picker plans the same route before enabling Start, so this should be
      // unreachable. Log rather than throw: a crash inside the foreground-service
      // isolate takes the whole ride down silently.
      _log('Cannot plan $originId -> $destinationId: $error');
      return;
    }
    _journey = journey;
    _rideProgress = RideProgress(
      chain: journey.chain,
      destinationStationId: journey.destinationStationId,
      overshootStations: journey.overshootStations,
      approachRadiusM: journey.approachRadiusM,
      arrivalAnnouncements: journey.arrivalAnnouncements,
    );
    _windDown = WindDown(
      destination: journey.chain
          .firstWhere((s) => s.id == journey.destinationStationId),
      overshootStations: journey.overshootStations,
    );
    // The wake engine watches the same critical stations the journey
    // defines: the interchanges THIS route requires, then the destination
    // (locked decision 6), all in chain order as the planner emits them.
    _wakeEscalation = WakeEscalation(
      chain: journey.chain,
      interchangeStationIds: [
        for (final interchange in journey.interchanges) interchange.stationId,
      ],
      destinationStationId: journey.destinationStationId,
    );
    _wakeOutput =
        WakeAlertOutput(log: _log, onIosToneCommand: onIosToneCommand);

    if (sarvamClips && Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      final root =
          dir == null ? null : Directory('${dir.path}/clips/en-IN');
      final clips = root != null && await root.exists()
          ? ClipLibrary.open(root)
          : null;
      if (clips != null) {
        _clips = clips;
        _log('CLIPS enabled from ${root!.path}, ${clips.length} in manifest');
      } else if (root != null && await root.exists()) {
        _log('CLIPS pack has no readable manifest.json, using device TTS. '
            'Regenerate with build_clip_pack.py --manifest-only and push it.');
      } else {
        _log('CLIPS requested but no pack found, using device TTS.');
      }
    }

    await _configureAudio();

    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);
    await _tts.awaitSpeakCompletion(true);
    if (Platform.isAndroid) {
      // flutter_tts defaults to QUEUE_FLUSH on Android: a second speak()
      // cuts off whatever is still playing. If a GPS gap drops the first
      // fix inside both of a two-stage station's fences, both ENTERs speak
      // back-to-back and the long interchange script could be flushed
      // mid-sentence by the short approach ping. QUEUE_ADD (1) plays each
      // announcement in full, in order. iOS queues natively and does not
      // implement setQueueMode, hence the platform guard.
      await _tts.setQueueMode(1);
    }

    Geofencing.instance.setup(printsDebugLog: true);
    Geofencing.instance.addGeofenceStatusChangedListener(_onStatusChanged);
    Geofencing.instance.addGeofenceErrorCallbackListener(_onGeofenceError);

    final approachRadiusM = journey.approachRadiusM;
    final regions = <GeofenceRegion>{};
    // The overshoot pins need fences too. They are not chain members (they can
    // fork past a terminus), but the net is worthless without a trigger: on
    // 13 Jul the overshoot warning fired off the pin's native fence.
    for (final station in [...journey.chain, ...journey.overshootStations]) {
      regions.add(
        GeofenceRegion.circular(
          id: station.id,
          data: station.name,
          center: LatLng(station.lat, station.lng),
          radius: station.radiusM.toDouble(),
        ),
      );
      final approachRadius = approachRadiusM[station.id];
      if (approachRadius != null) {
        regions.add(
          GeofenceRegion.circular(
            id: '${station.id}$_approachSuffix',
            data: station.name,
            center: LatLng(station.lat, station.lng),
            radius: approachRadius.toDouble(),
          ),
        );
      }
    }

    _log(
      'Planned journey: ${journey.chain.map((s) => s.name).join(' -> ')}',
    );
    for (final interchange in journey.interchanges) {
      _log(
        'Change trains at ${interchange.stationId} onto '
        '${interchange.toLineShortName} towards '
        '${interchange.towardsStationName}'
        '${interchange.platform == null ? '' : ' (platform ${interchange.platform})'}',
      );
    }

    try {
      // Independent of geofencing_api's own internal fl_location stream:
      // logs every raw fix (including ones geofencing_api would silently
      // drop for low accuracy) so a real ride's log proves whether GPS
      // fixes are arriving at all, and at what accuracy.
      _rawLocationSub = fl.FlLocation.getLocationStream(
        accuracy: fl.LocationAccuracy.navigation,
        // Ask for ~1 Hz (fl_location default is 5000ms). iOS already delivers
        // ~1s; on Android this tightens cadence WHEN GPS is flowing, giving the
        // RideProgress backstop more fixes and better lead time. It does NOT
        // beat OEM Doze gaps (a phone that suppresses location for minutes
        // ignores this) - that is the separate background-survival fix.
        interval: 1000,
      ).listen(_onRawLocation, onError: _onRawLocationError);

      await Geofencing.instance.start(regions: regions);
    } catch (error) {
      _log('Geofencing chain failed to start: $error');
    }

    // Spoken the moment the ride is live: confirms through the earphones
    // that Travel Mode (and the audio path every announcement depends on)
    // actually started, and teaches the one gesture that ends it.
    final destinationName = journey.chain
        .firstWhere((s) => s.id == journey.destinationStationId)
        .name;
    final welcomeBody =
        'Travel Mode is on, from '
        '${journey.chain.first.name} to $destinationName. I will announce '
        'each station along the way. To end the journey at any time, press '
        'and hold the End journey button.';
    if (sarvamGreeting && Platform.isAndroid) {
      // Clip greets, TTS still speaks the dynamic route line: the route
      // confirmation and the TTS-path self-test both survive the clip.
      unawaited(_greetThenSpeak(welcomeBody));
    } else {
      final welcome = _fullWelcome(welcomeBody);
      _log('SPEAK welcome: $welcome');
      unawaited(_speak(welcome));
    }
  }

  /// The one place the spoken greeting sentence joins the route line, so the
  /// clipless path and the clip-failure path cannot drift apart.
  static String _fullWelcome(String welcomeBody) =>
      'Welcome to Commute Guardian. $welcomeBody';

  /// The Sarvam clip that can replace this announcement, or null for TTS.
  /// Null whenever clips are off, the pack lacks the file, or the sentence
  /// is not byte-identical to the clip's template (interchange scripts and
  /// other dynamic lines always miss on purpose; see clip_library.dart).
  File? _clipForAnnouncement(Announcement announcement) {
    final clips = _clips;
    final chain = _journey?.chain;
    if (clips == null || chain == null) return null;
    final index = chain.indexWhere((s) => s.id == announcement.stationId);
    if (index == -1) return null;
    final kind = announcementClipKind(
      announcement: announcement,
      stationName: chain[index].name,
    );
    if (kind == null) return null;
    return clips.clipFor(
      announcement.stationId,
      kind,
      expectedSentence: announcement.text,
    );
  }

  /// Queues a clip behind any clips already playing. A failed clip drops to
  /// the device TTS floor with the exact same sentence, so the rider loses
  /// the nicer voice, never the information.
  void _enqueueClip(File clip, {required String floorText}) {
    _clipChain = _clipChain.then((_) async {
      try {
        _log('CLIP ${clip.uri.pathSegments.last}');
        await _playClipFile(clip);
      } catch (error) {
        _log('CLIP failed, using device TTS: $error');
        await _speak(floorText);
      }
      // Nothing may escape into the chain itself. A rejected future here
      // poisons every clip queued after it for the rest of the ride, which
      // would silence announcements one by one instead of dropping a single
      // one to the floor.
    }).catchError((Object error) {
      _log('CLIP chain error, queue continues: $error');
    });
  }

  /// Plays one clip file through the announcement duck: music dips while
  /// the clip speaks, comes back after, same shape as the greeting slice.
  Future<void> _playClipFile(File clip) async {
    final player = ap.AudioPlayer();
    try {
      await player.setAudioContext(_clipDuckContext);
      final completed = player.onPlayerComplete.first..ignore();
      _selfInterruption.noteOwnAudioStarted(DateTime.now());
      await player.play(ap.DeviceFileSource(clip.path));
      // The longest templates run ~8 s; a wedged player must not dam the
      // clip chain for the rest of the ride.
      await completed.timeout(const Duration(seconds: 12));
    } finally {
      unawaited(player.release());
    }
  }

  /// Android transient duck, the same shape [_speak]'s session takes: the
  /// clip is a navigation prompt, not a media track.
  static final ap.AudioContext _clipDuckContext = ap.AudioContext(
    android: const ap.AudioContextAndroid(
      isSpeakerphoneOn: false,
      audioMode: ap.AndroidAudioMode.normal,
      stayAwake: false,
      contentType: ap.AndroidContentType.speech,
      usageType: ap.AndroidUsageType.assistanceNavigationGuidance,
      audioFocus: ap.AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  /// Plays the bundled greeting clip, then hands over to the normal TTS
  /// welcome. Every failure path falls through to TTS: the clip is an
  /// enhancement and must never cost the rider the route confirmation.
  Future<void> _greetThenSpeak(String welcomeBody) async {
    final player = ap.AudioPlayer();
    try {
      _log('GREETING clip: welcome_greeting.wav');
      await player.setAudioContext(_clipDuckContext);
      // ignore() marks the future safe if play() throws before the await
      // reaches it; otherwise its error would surface unhandled later.
      final completed = player.onPlayerComplete.first..ignore();
      await player.play(ap.AssetSource('audio/welcome_greeting.wav'));
      // The clip is ~3s; a wedged player must not hold the welcome hostage.
      await completed.timeout(const Duration(seconds: 6));
    } catch (error) {
      _log('GREETING clip failed, using device TTS: $error');
      await _speak(_fullWelcome(welcomeBody));
      return;
    } finally {
      unawaited(player.release());
    }
    _log('SPEAK welcome: $welcomeBody');
    await _speak(welcomeBody);
  }

  /// The announcement session: duck the rider's music while speaking, get out
  /// of the way after.
  ///
  /// `speech()` on its own is EXCLUSIVE on iOS (category playback, no
  /// options): activating it over a podcast interrupts the podcast rather
  /// than ducking it, and its spokenAudio mode means "PAUSE other audio on
  /// activation" (it exists for podcast apps); that is what STOPPED the
  /// rider's music outright in the 13 Jul bench test. Duck + mix under the
  /// voicePrompt (navigation prompt) mode is the wanted shape: duck, talk,
  /// get out of the way. notifyOthersOnDeactivation is what actually tells
  /// the other app to come back to full volume when we deactivate. On
  /// Android, `speech()` asks for AUDIOFOCUS_GAIN (permanent), which tells a
  /// music app to stop and never hands focus back; transient may-duck is what
  /// a navigation prompt takes, and we must not duck ourselves.
  static final AudioSessionConfiguration _duckProfile =
      const AudioSessionConfiguration.speech().copyWith(
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers |
        AVAudioSessionCategoryOptions.mixWithOthers,
    avAudioSessionMode: AVAudioSessionMode.voicePrompt,
    avAudioSessionSetActiveOptions:
        AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidAudioAttributes: const AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.assistanceNavigationGuidance,
    ),
    androidWillPauseWhenDucked: false,
  );

  /// The ladder seized the session exclusively (tone context has no
  /// mixWithOthers on iOS, and the UI-side native seizure owns Now Playing).
  /// On stand-down, put the duck profile back so the next ordinary
  /// announcement ducks the rider's music instead of interrupting it, then
  /// release the session so the music comes back at all.
  Future<void> _releaseLadderAudio() async {
    try {
      await _session?.configure(_duckProfile);
      if (_pendingSpeaks == 0) {
        await _session?.setActive(false);
      }
    } catch (error) {
      _log('Could not restore the announcement audio profile: $error');
    }
  }

  /// Configures a ducking spoken-audio session, but deliberately does NOT
  /// activate it: [_speak] activates only for as long as it is actually
  /// speaking. Holding the session active for the whole ride is what caused the
  /// 12 Jul field bug, where a podcast already playing when Travel Mode started
  /// was ducked and then stayed quiet for the rest of the journey.
  Future<void> _configureAudio() async {
    final session = await AudioSession.instance;
    _session = session;
    await session.configure(_duckProfile);

    // The wake engine's call signal (locked decision 8: on a call means
    // awake). An interruption suspends a live ladder; its end delivers the
    // catch-up. The log lines are load-bearing: replay_ride.dart parses
    // them to reproduce call handling from a real ride's log.
    _interruptionSub = session.interruptionEventStream.listen((event) {
      final now = DateTime.now();
      // Our own clip colliding with our own speech raises this same event, and
      // feeding that to the engine stood a live ladder DOWN (21 Jul bench,
      // reproduced 2 for 2; the 20 Jul Vasind case in the field). Withheld
      // events are still logged, distinctly: replay_ride.dart parses these
      // lines to reproduce call handling, and a silently dropped line would
      // change how old rides replay.
      if (_selfInterruption.shouldIgnore(begin: event.begin, now: now)) {
        _log(
          event.begin
              ? 'Audio session interrupted by our own audio, ignored.'
              : 'Audio session interruption ended (ours, ignored).',
        );
        return;
      }
      _log(
        event.begin
            ? 'Audio session interrupted (call or other audio).'
            : 'Audio session interruption ended.',
      );
      _handleWakeActions(
        _wakeEscalation?.onCallStateChanged(
              inCall: event.begin,
              now: now,
            ) ??
            const [],
      );
    });

    if (Platform.isIOS) {
      // Makes flutter_tts speak through the shared session configured above
      // instead of standing up a second one of its own. CAUTION: inside the
      // plugin this call also runs AVAudioSession.setActive(true), which is
      // what grabbed audio focus the moment Travel Mode started in the 13 Jul
      // bench test. It is undone right below.
      await _tts.setSharedInstance(true);
      // flutter_tts deactivates the session after EVERY utterance, which would
      // bob the music's volume between the two back-to-back announcements of a
      // two-stage station. _speak owns the deactivation instead, releasing once
      // per RUN of announcements.
      await _tts.autoStopSharedSession(false);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
      // Release the focus setSharedInstance grabbed. Travel Mode idling between
      // stations must not hold the duck; _speak activates per announcement and
      // the configured notifyOthersOnDeactivation tells other apps to come back
      // to full volume.
      try {
        await session.setActive(false);
      } catch (error) {
        _log('Could not release audio session at start: $error');
      }
    }
  }

  /// Speaks [text], ducking other audio only for the duration of the speech.
  ///
  /// Calls are serialized on one chain, so a fix arriving mid-announcement
  /// queues behind it rather than cutting it off. The session is deactivated
  /// only once the last queued announcement has finished, so a run of them (the
  /// Thane approach ping followed by the interchange script) ducks the music
  /// once rather than bobbing its volume between sentences.
  Future<void> _speak(String text) {
    _pendingSpeaks++;
    _speaking = _speaking.then((_) async {
      try {
        // Activating the session is itself one half of the collision, so the
        // window opens here rather than after the utterance starts.
        _selfInterruption.noteOwnAudioStarted(DateTime.now());
        await _session?.setActive(true);
        await _tts.speak(text);
      } catch (error) {
        // Swallowed so one failed announcement cannot poison the chain and
        // silence every announcement after it for the rest of the ride.
        _log('Announcement failed: $error');
      } finally {
        _pendingSpeaks--;
        // While a wake ladder is live the session must STAY active: on iOS
        // the audio context is the app-wide shared AVAudioSession, and
        // deactivating it here is what silenced the looping alarm tone the
        // moment rung 1's speech finished (15 Jul iPhone bench). The ladder
        // releases the session itself when it stands down.
        if (_pendingSpeaks == 0 && !_wakeLadderLive) {
          await _session?.setActive(false);
        }
      }
    });
    return _speaking;
  }

  /// Debug-only: speaks a test line through the same [FlutterTts] instance
  /// and isolate real station announcements use, without needing a real or
  /// mocked GPS fix to trigger a geofence ENTER.
  Future<void> testAnnounce() async {
    _log('Test announcement requested.');
    // With clips on, the test exercises the REAL clip path end to end
    // (selection, queue, duck, file playback) with the origin's approach
    // clip; a bench in a living room never enters a fence, so this is the
    // only way to hear the path before a ride does. Clips off, or the file
    // missing, keeps the stock TTS self-test.
    final chain = _journey?.chain;
    if (_clips != null && chain != null && chain.isNotEmpty) {
      final origin = chain.first;
      final text = ClipKind.approach.render(origin.name);
      final clip = _clipForAnnouncement(
        Announcement(
          stationId: origin.id,
          kind: AnnouncementKind.approach,
          text: text,
        ),
      );
      if (clip != null) {
        _enqueueClip(clip, floorText: text);
        return;
      }
    }
    await _speak(
      'This is a test announcement from Commute Guardian. '
      'If you can hear this, text to speech is working.',
    );
  }

  /// Debug-only: benches the REAL wake engine with no train, by feeding it
  /// the arrival at the first critical station's trigger (one stop before
  /// it), exactly what RideProgress would emit there. Everything downstream
  /// is live: check-in, rungs, tone, vibration, media-session ack. Because
  /// no ceiling station will ever arrive at the bench, a synthesized
  /// ceiling arrival ends an unacknowledged test through the same real
  /// path after [_wakeTestTimeout].
  Future<void> testWakeAlert() async {
    final engine = _wakeEscalation;
    final journey = _journey;
    if (engine == null || journey == null) {
      _log('WAKE test ignored: no ride is running.');
      return;
    }
    if (engine.isLadderLive) {
      _log('WAKE test ignored: a ladder is already live.');
      return;
    }
    final chain = journey.chain;
    final firstTargetId = journey.interchanges.isNotEmpty
        ? journey.interchanges.first.stationId
        : journey.destinationStationId;
    final targetIndex = chain.indexWhere((s) => s.id == firstTargetId);
    if (targetIndex <= 0) {
      _log('WAKE test ignored: no trigger station before $firstTargetId.');
      return;
    }
    final trigger = chain[targetIndex - 1];
    _wakeTestCeiling =
        targetIndex + 1 < chain.length ? chain[targetIndex + 1] : null;
    _wakeTestCeilingAt = DateTime.now().add(_wakeTestTimeout);
    _log('WAKE test: synthesizing arrival at ${trigger.name}.');
    _handleWakeActions(
      engine.onStationEvent(
        Announcement(
          stationId: trigger.id,
          kind: AnnouncementKind.arrival,
          text: 'Wake test arrival.',
        ),
        DateTime.now(),
      ),
    );
  }

  /// An acknowledgment from outside the service isolate: the earphone tap
  /// (native media session, forwarded by the UI isolate) or the on-screen
  /// "I'm awake" button.
  /// [source] names which path acked so the log file can tell an earphone tap
  /// from the on-screen button. Logged BEFORE the engine is asked, so a tap
  /// that arrives when no ladder is live still leaves a trace.
  void wakeAck({String? source}) {
    _log('WAKE ack from ${source ?? 'unknown'}.');
    _handleWakeActions(
      _wakeEscalation?.acknowledge(DateTime.now()) ?? const [],
    );
  }

  /// Maps the wake engine's decisions onto the proven hardware paths, and
  /// mirrors the ladder's live state out to the UI (media session,
  /// "I'm awake" button) and the iOS audio-session hold.
  void _handleWakeActions(List<WakeAction> actions) {
    for (final action in actions) {
      switch (action) {
        case Speak(:final text):
          _log('WAKE speak: $text');
          unawaited(_speak(text));
        case Tone(:final volume):
          _log('WAKE tone ${volume.toStringAsFixed(1)}.');
          _wakeToneVolume = volume;
          unawaited(_wakeOutput?.ensureToneAt(volume));
        case StopTone():
          _wakeToneVolume = null;
          unawaited(_wakeOutput?.stopTone());
        case Vibrate():
          unawaited(_wakeOutput?.vibrate());
        case HardStop():
          _log('WAKE hard stop: ceiling reached, ladder given up.');
          _wakeToneVolume = null;
          unawaited(_wakeOutput?.stopTone());
      }
    }

    final live = _wakeEscalation?.isLadderLive ?? false;
    if (live != _wakeLadderLive) {
      _wakeLadderLive = live;
      _log('WAKE ladder ${live ? 'live' : 'stood down'}.');
      if (!live) {
        _wakeTestCeilingAt = null;
        _wakeTestCeiling = null;
        unawaited(_releaseLadderAudio());
      }
      onWakeLadderLive?.call(live);
    }
  }

  /// Debug-only: drives the REAL wind-down path end to end at the bench,
  /// with no train. Feeds the engine the destination arrival, then two
  /// synthetic walking-speed fixes just outside the fence, exactly what a
  /// real platform exit produces. Everything downstream is live: countdown
  /// line, notification buttons, Extend, and the auto-off teardown 60
  /// seconds later.
  Future<void> testWindDown() async {
    final windDown = _windDown;
    final journey = _journey;
    if (windDown == null || journey == null) {
      _log('WIND_DOWN test ignored: no ride is running.');
      return;
    }
    _log('WIND_DOWN test requested.');
    final destination = journey.chain
        .firstWhere((s) => s.id == journey.destinationStationId);
    final now = DateTime.now();
    _handleWindDownActions(
      windDown.onStationEvent(
        Announcement(
          stationId: destination.id,
          kind: AnnouncementKind.arrival,
          text: 'Wind-down test arrival.',
        ),
        now,
      ),
    );
    // The alight dwell first: the train standing at the platform (inside
    // the fence, walking speed). Exit fixes count for nothing without it.
    _handleWindDownActions(
      windDown.onFix(
        lat: destination.lat,
        lng: destination.lng,
        accuracyM: 10,
        speedMps: 0.3,
        now: now,
      ),
    );
    // Then walking-speed fixes due north, well past the exit walk
    // distance from the alight anchor; only the distance matters.
    final lat = destination.lat + (destination.radiusM + 200) / 111000.0;
    for (var i = 0; i < WindDown.exitFixesRequired; i++) {
      _handleWindDownActions(
        windDown.onFix(
          lat: lat,
          lng: destination.lng,
          accuracyM: 10,
          speedMps: 1.0,
          now: now.add(Duration(seconds: i + 1)),
        ),
      );
    }
  }

  Future<void> stop() async {
    // The engine dies first so nothing re-starts the tone mid-teardown; a
    // ride ended mid-ladder must also release the UI's media session.
    _wakeEscalation = null;
    _wakeTestCeilingAt = null;
    _wakeTestCeiling = null;
    _wakeToneVolume = null;
    await _wakeOutput?.stopTone();
    await _wakeOutput?.dispose();
    _wakeOutput = null;
    if (_wakeLadderLive) {
      _wakeLadderLive = false;
      onWakeLadderLive?.call(false);
    }

    // A manual End mid-countdown must not leave phantom wind-down buttons.
    _windDown = null;
    if (_windDownLive) {
      _windDownLive = false;
      onWindDownLive?.call(false);
    }

    // The goodbye must speak BEFORE teardown (after _tts.stop() nothing
    // can), and it is awaited so onDestroy keeps the isolate alive until it
    // finishes. Bounded: a hung TTS engine must never wedge the service in
    // its dying moments, so on timeout the teardown just proceeds and cuts
    // the speech off.
    if (Platform.isAndroid) {
      // The Android plugin honors awaitSpeakCompletion ONLY in QUEUE_FLUSH
      // mode; under the ride's QUEUE_ADD it returns at once, so the await
      // below was a no-op and _tts.stop() cut the farewell 100ms in on
      // every 15 Jul bench run. The ride is over and nothing is worth
      // queueing behind, so switch back to flush for this last utterance.
      await _tts.setQueueMode(0);
    }
    const farewell = 'Thank you for using Commute Guardian.';
    _log('SPEAK farewell: $farewell');
    await _speak(
      farewell,
    ).timeout(const Duration(seconds: 8), onTimeout: () {});

    Geofencing.instance.removeGeofenceStatusChangedListener(_onStatusChanged);
    Geofencing.instance.removeGeofenceErrorCallbackListener(_onGeofenceError);
    await Geofencing.instance.stop();
    await _rawLocationSub?.cancel();
    _rawLocationSub = null;
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    await _tts.stop();
    // Hands audio focus back, in case Stop was pressed mid-announcement.
    await _session?.setActive(false);
    _session = null;
    _rideProgress = null;
    _journey = null;
    _log('Geofence chain stopped.');
    _logFile = null;
  }

  /// One file per Travel Mode session, on Android under the app's
  /// external files dir (`Android/data/<package>/files`), pullable with
  /// `adb pull` with no extra storage permission needed. Survives even if
  /// the on-screen log list is lost to Activity recreation during a long
  /// backgrounded ride.
  Future<File> _createLogFile() async {
    final dir = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final base = dir ?? await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(
          RegExp(r'[:.]'),
          '-',
        );
    final file = File('${base.path}/geofence_log_$stamp.txt');
    return file.create(recursive: true);
  }

  Future<void> _onStatusChanged(
    GeofenceRegion region,
    GeofenceStatus status,
    Location location,
  ) async {
    if (status != GeofenceStatus.enter) {
      return;
    }

    final isApproach = region.id.endsWith(_approachSuffix);
    final stationId = isApproach
        ? region.id.substring(0, region.id.length - _approachSuffix.length)
        : region.id;
    // A stale event for a fence this journey does not own (regions from a
    // previous ride racing a stop/start) must not throw here: an uncaught
    // error inside the service isolate takes the whole ride down. Note
    // firstWhere throws on no match, so a null check on it guards nothing.
    final chain = _journey?.chain;
    if (chain == null) {
      return;
    }
    final index = chain.indexWhere((s) => s.id == stationId);
    if (index == -1) {
      return;
    }
    final station = chain[index];

    // Logged for native-vs-backstop comparison only. RideProgress (fed by the
    // raw location stream in _onRawLocation) is the single source of spoken
    // announcements now, so the native ENTER no longer speaks.
    _log(
      'ENTER ${isApproach ? 'APPROACH' : 'ARRIVE'} ${station.name} (native) '
      '(fix ${location.latitude.toStringAsFixed(5)}, '
      '${location.longitude.toStringAsFixed(5)}, '
      'accuracy ${location.accuracy.toStringAsFixed(0)}m)',
    );
  }

  Future<void> _onRawLocation(fl.Location location) async {
    onRawFix?.call(location);
    _log(
      'FIX lat ${location.latitude.toStringAsFixed(5)}, '
      'lng ${location.longitude.toStringAsFixed(5)}, '
      'accuracy ${location.accuracy.toStringAsFixed(0)}m, '
      'speed ${location.speed.toStringAsFixed(1)}m/s, '
      'heading ${location.heading.toStringAsFixed(0)}, '
      'mock ${location.isMock}',
    );

    // RideProgress, fed by every raw fix, is the single source of spoken
    // announcements: it still fires a station the native geofence engine
    // jumped or a blackout hid (see ride_progress.dart).
    final announcements = _rideProgress?.onFix(
          lat: location.latitude,
          lng: location.longitude,
          accuracyM: location.accuracy,
        ) ??
        const <Announcement>[];
    final now = DateTime.now();
    for (final announcement in announcements) {
      // The SPEAK line's format is load-bearing: replay_ride.dart parses it.
      _log(
        'SPEAK ${announcement.kind.name} ${announcement.stationId}: '
        '${announcement.text}',
      );
      final clip = _clipForAnnouncement(announcement);
      if (clip != null) {
        _enqueueClip(clip, floorText: announcement.text);
      } else {
        unawaited(_speak(announcement.text));
      }

      if (announcement.kind == AnnouncementKind.arrival &&
          announcement.stationId == _journey?.destinationStationId) {
        onDestinationReached?.call();
      }

      _handleWindDownActions(
        _windDown?.onStationEvent(announcement, now) ?? const [],
      );
      _handleWakeActions(
        _wakeEscalation?.onStationEvent(announcement, now) ?? const [],
      );
    }

    _handleWindDownActions(
      _windDown?.onFix(
            lat: location.latitude,
            lng: location.longitude,
            accuracyM: location.accuracy,
            speedMps: location.speed,
            now: now,
          ) ??
          const [],
    );
    _handleWakeActions(
      _wakeEscalation?.onFix(
            lat: location.latitude,
            lng: location.longitude,
            accuracyM: location.accuracy,
            speedMps: location.speed,
            now: now,
          ) ??
          const [],
    );
  }

  /// The service's fixed 5 second repeat tick, forwarded by the task
  /// handler. Drives the wind-down countdown and the wake ladder's clock.
  void onTick(DateTime now) {
    _handleWindDownActions(_windDown?.onTick(now) ?? const []);

    // Bench-test safety net: synthesize the ceiling arrival the missing
    // train would have produced, through the same real engine path.
    final testCeilingAt = _wakeTestCeilingAt;
    if (testCeilingAt != null && !now.isBefore(testCeilingAt)) {
      _wakeTestCeilingAt = null;
      final ceiling = _wakeTestCeiling;
      _wakeTestCeiling = null;
      if (ceiling != null && (_wakeEscalation?.isLadderLive ?? false)) {
        _log('WAKE test: timeout, synthesizing ceiling at ${ceiling.name}.');
        _handleWakeActions(
          _wakeEscalation!.onStationEvent(
            Announcement(
              stationId: ceiling.id,
              kind: AnnouncementKind.arrival,
              text: 'Wake test ceiling.',
            ),
            now,
          ),
        );
      } else if (_wakeEscalation?.isLadderLive ?? false) {
        // No station past the target (terminus destination): stand the
        // bench ladder down as if acknowledged rather than blast forever.
        _log('WAKE test: timeout with no ceiling station, standing down.');
        _handleWakeActions(_wakeEscalation!.acknowledge(now));
      }
    }

    _handleWakeActions(_wakeEscalation?.onTick(now) ?? const []);

    // The tone watchdog (15 Jul iOS bench: TTS finishing could kill the
    // shared session and the looping tone with it, leaving ~13 silent
    // seconds until the next rung restarted it). Re-asserting the tone at
    // the current rung volume every tick caps any gap at ~5 seconds.
    final toneVolume = _wakeToneVolume;
    if (_wakeLadderLive && toneVolume != null) {
      unawaited(_wakeOutput?.ensureToneAt(toneVolume));
    }
  }

  /// [End now], from the notification button or the debug screen.
  void windDownEndNow() {
    _log('WIND_DOWN End now pressed.');
    _handleWindDownActions(_windDown?.endNow(DateTime.now()) ?? const []);
  }

  /// [Extend 10 min], from the notification button or the debug screen.
  void windDownExtend() {
    _log('WIND_DOWN Extend pressed.');
    _handleWindDownActions(_windDown?.extend(DateTime.now()) ?? const []);
  }

  void _handleWindDownActions(List<WindDownAction> actions) {
    for (final action in actions) {
      switch (action) {
        case WindDownSpeak(:final text):
          _log('SPEAK wind-down: $text');
          unawaited(_speak(text));
        case WindDownEnd():
          _log('WIND_DOWN ending Travel Mode.');
          onAutoOff?.call();
      }
    }
    // Mirrors the countdown state out to the notification buttons and the
    // debug screen, only on change.
    final live = _windDown?.isCountingDown ?? false;
    if (live != _windDownLive) {
      _windDownLive = live;
      _log('WIND_DOWN countdown ${live ? 'started' : 'stopped'}.');
      onWindDownLive?.call(live);
    }
  }

  void _onRawLocationError(Object error, StackTrace stackTrace) {
    _log('Raw location stream error: $error');
  }

  void _onGeofenceError(Object error, StackTrace stackTrace) {
    _log('Geofencing error: $error');
  }

  void _log(String message) {
    dev.log(message, name: 'GeofenceChain');
    onLog(message);
    _logFile?.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
