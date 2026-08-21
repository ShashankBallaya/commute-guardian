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
import '../models/app_settings.dart';
import '../models/journey.dart';
import '../models/station.dart';
import 'analytics.dart';
import 'announcement_templates.dart';
import 'audio_session_idle.dart';
import 'bundled_clips.dart';
import 'clip_library.dart';
import 'duck_audio_context.dart';
import 'player_completion.dart';
import 'pocket_pulse.dart';
import 'pulse_output.dart';
import 'ride_health.dart';
import 'ride_progress.dart';
import 'thermal_gateway.dart';
import 'ride_timeout.dart';
import 'self_audio_interruption.dart';
import 'spoken_copy.dart';
import 'wake_alert_output.dart';
import 'wake_escalation.dart';
import 'wake_suspension.dart';
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
    this.onProgress,
    this.onWakeLadderLive,
    this.onWindDownLive,
    this.onAlightingAt,
    this.onAutoOff,
    this.onIosToneCommand,
    this.onIosVibrate,
    this.sarvamGreeting = false,
    this.sarvamClips = false,
    Analytics? analytics,
    ThermalGateway? thermal,
  }) : _analytics = analytics ?? Analytics(enabled: false),
       _thermal = thermal ?? const ThermalGateway();

  /// How hot the phone says it is. Injected like [_analytics], so a replay or a
  /// desk test can hand in a fake instead of a method channel that no test
  /// binding answers.
  final ThermalGateway _thermal;

  /// The last state written to the ride log, so only CHANGES are recorded. A
  /// line a minute saying "nominal" would bury the moment it stopped being
  /// nominal, which is the only moment anyone will ever look for.
  ThermalState? _lastThermal;

  /// When the phone was last asked. Every 60 s: thermal state moves over
  /// minutes of sustained load, not seconds, and this rides the same tick as
  /// the pulse and the wind-down.
  DateTime? _thermalAskedAt;
  static const _thermalInterval = Duration(seconds: 60);

  /// The two analytics events this app has, and the rider's opt-out.
  ///
  /// Injected rather than reached for, so a test can watch what a ride would
  /// have reported without a network, and so the DEFAULT is disabled: a
  /// GeofenceChainService built without being handed one sends nothing, which
  /// is the right way round for a switch about a rider's data.
  final Analytics _analytics;

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

  /// Fires when the rider provably reaches a further station along the chain,
  /// carrying [RideProgress.reachedIndex].
  ///
  /// Screen 4 draws the whole ride from this. It is emitted from HERE rather
  /// than re-derived in the UI from the raw fix stream, so that the chain has
  /// exactly one projector. Fires only on CHANGE, so a 1 Hz fix stream does not
  /// become a 1 Hz stream of identical messages across the isolate boundary.
  final void Function(int reachedIndex, bool atStation)? onProgress;

  /// Fires when the wake ladder starts asking to be acknowledged, stands down,
  /// or CLIMBS A RUNG.
  ///
  /// The UI listens so it can show its manual "I'm awake" button and hold the
  /// native media session (the thing that routes an earphone tap to us) only
  /// while a ladder is actually asking to be acknowledged. The rung drives the
  /// alert screen's glow; liveness alone would hold the quietest glow through
  /// the loudest alarm.
  final void Function(bool live, int rung, bool climbing)? onWakeLadderLive;

  /// Fires when the post-arrival auto-off countdown starts, stops, or has its
  /// deadline moved. The handler mirrors it into the notification's [End now]
  /// and [Extend 10 min] buttons, the debug screen's equivalents, and Screen 5.
  ///
  /// Carries the deadline because Screen 5 shows the rider how long they have.
  /// AN EXTEND MOVES THE DEADLINE WITHOUT CHANGING [live], so anything watching
  /// only liveness would show the old countdown for ten more minutes.
  final void Function(bool live, DateTime? endsAt, Duration window)?
  onWindDownLive;

  /// Fires when the station the rider will alight at changes, which happens
  /// exactly once per overshoot and never on a ride that goes to plan.
  ///
  /// SEPARATE FROM [onWindDownLive] because a re-arm at an overshoot pin does
  /// not change liveness or the deadline, so anything keyed to those would miss
  /// it entirely. That is the same trap the wind-down deadline and the wake
  /// rung both fell into: the flag is not the state.
  final void Function(String stationId)? onAlightingAt;

  /// The auto-off countdown expired (or [End now] was pressed): the ride is
  /// over and the whole service should tear itself down. Owned by the
  /// handler because only it may stop the foreground service.
  final void Function()? onAutoOff;

  /// iOS only: carries a ladder tone command ('startTone'/'stopTone') toward
  /// the native AVAudioPlayer in AppDelegate, over the same
  /// service -> main -> media_ack hop the session seizure uses. See
  /// WakeAlertOutput.onIosToneCommand for why the tone left audioplayers.
  final void Function(String command, double volume)? onIosToneCommand;

  /// iOS Pocket Pulse vibration bench. See PulseOutput.buzz.
  final void Function()? onIosVibrate;

  Journey? _journey;

  final FlutterTts _tts = FlutterTts();
  RideProgress? _rideProgress;

  /// The last index handed to [onProgress]. Starts at -1, which is also
  /// RideProgress's "nothing confirmed yet", so a ride that has not reached a
  /// station never emits.
  int _lastPublishedIndex = -1;

  /// The at-station half of the last published position. See [onProgress].
  bool _lastPublishedAtStation = false;
  WakeEscalation? _wakeEscalation;
  WakeAlertOutput? _wakeOutput;
  WindDown? _windDown;

  /// The last rung published, so a climb is noticed as a change.
  int _wakeLadderRung = 0;

  bool _windDownLive = false;

  /// The last deadline published, so an Extend is noticed as a change.
  DateTime? _windDownEndsAt;

  /// The four-hour backstop for a ride nobody ended. Null between rides.
  RideTimeout? _rideTimeout;

  /// Two of the edge states, GPS_LOST and STALL. Notices only: it cannot move
  /// the chain or touch an alert.
  RideHealth? _rideHealth;

  /// The last alight station published, so a move to an overshoot pin is
  /// noticed as a change. Null until WindDown exists.
  String? _alightStationId;

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

  /// Pocket Pulse's hands. Built with the ride and nulled with it, which is
  /// what makes a pulse structurally unable to outlive the journey: there is
  /// nothing left for it to sound through. See docs/design/pocket-pulse.md.
  PulseOutput? _pulseOutput;

  /// Pocket Pulse's head: WHEN to chime. Rides the same [onTick] the other
  /// engines do, so the feature adds no timer and no wakeups.
  PocketPulse? _pocketPulse;

  /// Whether the rider asked for a buzz alongside the chime. Read from the
  /// store at start, like the interval.
  bool _pulseVibrate = true;

  /// Clips currently queued or playing. TTS has [_pendingSpeaks]; this is its
  /// counterpart, and together they are what "the app is talking right now"
  /// means to Pocket Pulse.
  int _pendingClips = 0;

  /// Pulse chimes currently sounding.
  ///
  /// NOT part of "the app is talking": the pulse is the least important sound
  /// this app makes and must never suppress anything. It exists only so the
  /// chime holds and releases the shared audio session like every other sound,
  /// which it did not do until the 14 Aug 2026 ride showed the rider's music
  /// staying ducked between announcements.
  int _pendingPulses = 0;

  /// How many announcements are queued or speaking. Drives the ducking window
  /// (the session is released only when the last one finishes) and Pocket
  /// Pulse's "the announcer is busy" suppression.
  ///
  /// The queue itself is [_audioChain] now, shared with clips. It used to be a
  /// separate `_speaking` future, which is exactly what let a clip start on top
  /// of a half-spoken welcome.
  int _pendingSpeaks = 0;

  /// Completed when the CURRENT utterance actually finishes speaking, on
  /// Android only.
  ///
  /// THIS EXISTS BECAUSE ANNOUNCEMENTS DID NOT DUCK THE RIDER'S MUSIC, on
  /// every Android ride, for the life of the project. `awaitSpeakCompletion`
  /// is honoured by the plugin ONLY in QUEUE_FLUSH mode, and the ride runs in
  /// QUEUE_ADD so a short approach ping cannot flush a long interchange
  /// script. Under QUEUE_ADD `speak()` returns AT ONCE, so [_speak]'s finally
  /// block ran while the words were still queued and deactivated the audio
  /// session 91 ms after activating it. Measured 30 Jul: requestAudioFocus at
  /// 22:41:06.465, abandonAudioFocus at 22:41:06.556, and `dumpsys audio`
  /// showed an empty ducked list for the whole announcement while the pulse
  /// chime (which holds its own focus for the sound's real duration) ducked
  /// correctly.
  ///
  /// The codebase already knew half of this: the farewell path works around
  /// the same fact by flipping to QUEUE_FLUSH for that one utterance. Nobody
  /// had connected it to ducking.
  Completer<void>? _utteranceDone;

  /// The pushed Sarvam clip pack, or null when clips are off or absent.
  ClipLibrary? _clips;

  /// What this ride speaks in, fixed at Start. Every engine was built with
  /// it, so nothing here may change it under a running ride.
  AppLanguage _language = AppLanguage.english;

  /// The ride's clipless sentences (welcome, farewell, the self test) in
  /// [_language]. The station and wake lines come from the clip-backed
  /// templates instead: see announcement_templates.dart.
  SpokenCopy _copy = const SpokenCopy();

  /// ONE QUEUE FOR EVERYTHING THE RIDE SAYS, clips and speech alike.
  ///
  /// This used to be a second, separate chain, and the comment on it accepted
  /// one race on purpose: "a clip starting while an earlier TTS line still
  /// speaks is accepted for this slice because Android TTS gives no completion
  /// to await mid-ride (QUEUE_ADD)".
  ///
  /// THAT PREMISE DIED ON 30 JUL 2026, when [_utteranceDone] was added to fix
  /// ducking. Android now waits for the ENGINE's completion, and iOS honours
  /// `awaitSpeakCompletion`, so on both platforms the speech future already
  /// resolves when the words actually stop. Nothing was left to accept, and
  /// the accepted race duly happened in the field.
  ///
  /// THE 13 AUG 2026 RIDE: the welcome began at 17:14:04.023 and the origin's
  /// clip began at 17:14:04.033, ten milliseconds later, two voices at once in
  /// the rider's earphones. Both rides that day opened that way, because the
  /// origin is announced on the ride's very first fix, which lands while the
  /// welcome is still talking.
  ///
  /// Merging the chains costs one ordering guarantee and buys the obvious one:
  /// nothing the app says can start until the last thing it said has finished.
  Future<void> _audioChain = Future<void>.value();

  /// Mirrors the spike's live state so [_speak] knows not to release the
  /// shared audio session while the alarm tone is looping.
  bool _wakeLadderLive = false;

  /// What this ride will report to analytics when it ends, and nothing more
  /// than this. Four booleans, no station, no line, no duration.
  ///
  /// They are HISTORICAL, unlike [_wakeLadderLive] and the rest of the live
  /// state, because the question they answer is asked at teardown when every
  /// live flag has already been cleared. "Did the alarm ever have to work on
  /// this ride, and did it" cannot be reconstructed from a flag that is false
  /// by the time anyone looks.
  bool _destinationAnnounced = false;
  bool _overshot = false;
  bool _timedOut = false;
  bool _wakeArmedThisRide = false;
  bool _wakeAnsweredThisRide = false;

  Future<void> start({
    required String originId,
    required String destinationId,
    // Pocket Pulse's settings arrive as VALUES, not as store keys, for the same
    // reason origin and destination do: the handler owns the store and this
    // owns the ride. Importing the handler's key constants here would make the
    // dependency circular.
    int pulseIntervalS = 0,
    bool pulseVibrate = true,
    // Also a VALUE from the store, for the same reason. It is read once, at
    // Start: a rider who changes language mid-ride keeps the voice the ride
    // began in, because every engine renders its sentences from the language
    // it was built with and the clip pack is opened from one directory.
    AppLanguage language = AppLanguage.english,
    // From the store, read once at Start like the language. See
    // [_mustAlwaysSpeak] for what "only your stop" is allowed to mean.
    bool announceEveryStation = true,
    // FROM THE STORE, never DateTime.now() here. A service the OS recreated
    // mid-ride calls start() again, and a fresh clock would hand a forgotten
    // ride another four hours, every time it was recreated.
    DateTime? rideStartedAt,
    // Measured by the UI at Start and carried through the store. A LOG LINE,
    // never a decision: nothing in the ride reads it.
    double? alarmVolume,
  }) async {
    _logFile = await _createLogFile();

    final locationAlways = await Permission.locationAlways.status;
    final ignoringBatteryOpt =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    // Notifications carry the ride's only UI-independent controls, and on iOS
    // they are the only acknowledgement route that survives the app being
    // swiped away or the earphone tap going to the music app. A rider who
    // answered "Not now" in onboarding therefore rides without an ack the
    // moment their screen is off, and nothing anywhere recorded that until
    // now. Recorded rather than acted on: a ride is the wrong moment to argue
    // with someone about a permission, and a log line is what tells us how
    // often it actually happens across the beta.
    final notifications = await Permission.notification.status;
    _log(
      'Permission state at start: locationAlways=$locationAlways, '
      'notifications=$notifications, '
      'ignoringBatteryOptimizations=$ignoringBatteryOpt',
    );
    // THE INSTRUMENT THE 11 AUG SILENT ALARM DID NOT HAVE. That ride log showed
    // the ladder go live, seize the session exclusively, and climb all three
    // rungs, while the owner heard nothing. Every layer reported success and
    // nothing recorded the one number that decides whether success is audible.
    //
    // Handed in rather than read here, because the channel that answers is
    // registered on the main engine and this isolate has its own. Negative or
    // absent means the platform would not say. Android reads STREAM_ALARM and
    // iOS reads outputVolume: see RideServiceClient.alarmVolume for why those
    // are different questions.
    _log(
      'Alarm volume at start: '
      '${alarmVolume == null || alarmVolume < 0 ? 'unavailable' : '${(alarmVolume * 100).round()}%'}',
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
    _language = language;
    _copy = SpokenCopy(language);
    if (language != AppLanguage.english) {
      _log('LANGUAGE ${language.tag}, announcements and clips both.');
    }
    // Every journey-shaped engine is built from the journey and nothing else,
    // through the factories, so the replay tool cannot drift from the service
    // the way it did when it silently stopped passing the overshoot pins.
    // RideHealth joined them when WRONG_DIRECTION gave it pins of its own.
    _rideProgress = RideProgress.forJourney(journey, language: language);
    _windDown = WindDown.forJourney(journey, language: language);
    _wakeEscalation = WakeEscalation.forJourney(journey, language: language);
    // A ride starting on a service that already ran one must not inherit a
    // raised sustained flag: it would spend the whole new ride treating real
    // calls as our own alarm. stop() clears it, but a restart that never went
    // through stop() would not.
    _selfInterruption.noteSustainedOwnAudioEnded();
    // THE WAKE TOGGLE RESETS EVERY RIDE, and this is where "per journey, never
    // sticky" is actually enforced. A service that already ran one ride must
    // not inherit an alarm the rider switched off in August, and neither must
    // a restarted one: this runs on every start(), not only on construction.
    _wakeEnabled = true;
    _inRealCall = false;
    _wakeSuspended = false;
    _announceEveryStation = announceEveryStation;
    _wakeOutput = WakeAlertOutput(
      log: _log,
      onIosToneCommand: onIosToneCommand,
      onIosVibrate: onIosVibrate,
    );
    _pulseOutput = PulseOutput(
      log: _log,
      interruptionFilter: _selfInterruption,
      onIosVibrate: onIosVibrate,
    );

    // The interval crosses the isolate boundary through the STORE, the same
    // way the Sarvam flags do, because settings live in drift and the service
    // isolate never opens that database. The store is also what a RESTARTED
    // service reads, which is what keeps the pulse alive across the restart
    // the 30 Jul swipe bench showed is possible.
    // ANDed WITH THE PLATFORM, not just honoured. iOS forbids background
    // haptics, which is a founding premise of this project, so PulseOutput.buzz
    // returns at its first line there. Storing the rider's raw preference made
    // an iPhone ride log claim "PULSE every 45s, with vibration" (10 Aug 2026,
    // 21:28, Shahad to Dombivli) for a buzz that could not physically happen.
    // A log that claims an output it cannot produce sends the next diagnosis
    // looking for a broken vibrator instead of a dead control, which is the same
    // lesson as the 22 Jul farewell that read as an auto-off.
    // STILL PLATFORM-GATED, and the 10 Aug rule is unchanged: this flag is what
    // the ride log CLAIMS, so it may never be true where no vibration is even
    // attempted. What changed on 11 Aug is that iOS now has a path to attempt
    // one (the kSystemSoundID_Vibrate bench), so the condition is "Android, or
    // iOS with the native hook wired" rather than "Android".
    //
    // It is still a claim about a REQUEST, never about a felt buzz. Whether iOS
    // honours the request from the background is the entire question the bench
    // exists to answer, and PulseOutput.buzz logs each attempt separately so
    // the log can be read either way.
    _pulseVibrate = pulseVibrate && (Platform.isAndroid || onIosVibrate != null);
    _pocketPulse = PocketPulse(
      intervalS: pulseIntervalS,
      startedAt: DateTime.now(),
    );
    _rideTimeout = RideTimeout(
      startedAt: rideStartedAt ?? DateTime.now(),
      language: language,
    );
    _rideHealth = RideHealth.forJourney(journey, language: language);
    // The count IS the measurement: weekly active riders means three or more
    // rides in a week, so this event carries no properties at all. Not
    // awaited, because nothing about starting a ride may wait on a network.
    unawaited(_analytics.trackRideStarted());
    if (pulseIntervalS > 0) {
      _log(
        'PULSE every ${pulseIntervalS}s'
        '${_pulseVibrate ? ", with vibration" : ""}.',
      );
    }

    if (sarvamClips) {
      // ONE RESOLUTION, SHARED WITH THE WRITER. BundledClips unpacks the
      // in-app pack into this exact directory at launch, so the reader and
      // the writer must agree on where it is; two copies of a path expression
      // is a silence waiting to happen. See bundled_clips.dart for why the
      // two platforms differ (they expose different reachable directories)
      // and for the per-language subdirectory rule.
      final dir = await BundledClips.clipsRoot();
      final root = dir == null
          ? null
          : Directory('${dir.path}/${language.tag}');
      final clips = root != null && await root.exists()
          ? ClipLibrary.open(root)
          : null;
      if (clips != null) {
        _clips = clips;
        _log('CLIPS enabled from ${root!.path}, ${clips.length} in manifest');
      } else if (root != null && await root.exists()) {
        _log(
          'CLIPS pack has no readable manifest.json, using device TTS. '
          'Rebuild it with tool/build_clip_assets.py.',
        );
      } else {
        _log('CLIPS requested but no pack found, using device TTS.');
      }
    }

    await _configureAudio();

    // The Settings picker only offers languages TtsLanguageGateway found on
    // this device, so this tag is one the engine answered to. If it somehow
    // is not, flutter_tts keeps its default voice and the words still come
    // out: wrong accent, never silence.
    await _tts.setLanguage(language.tag);
    await _tts.setSpeechRate(0.45);
    await _tts.awaitSpeakCompletion(true);
    // The single source of truth for "the words have stopped". Registered on
    // both platforms because it costs nothing, but only AWAITED on Android
    // (see _speak): iOS honours awaitSpeakCompletion and its shared-session
    // behaviour is device-proven, so it is left exactly as it was.
    // THE INSTRUMENT THE PRE-WARM QUESTION NEEDED, and never had. Section 4.2
    // asks for geofence-to-voice latency under one second, and the ride logs
    // could not answer it: every SPEAK line records when an announcement was
    // DECIDED, and the gap between that and the first sound was invisible. So
    // the six replays could not show a problem, which is not the same as
    // showing there is none.
    _tts.setStartHandler(_noteSpeechStarted);
    // Completion gets its own wrapper because it is the only one of the three
    // that means the engine reached the end of the sentence. A cancel and an
    // error also release the waiter, and logging a duration for either would
    // report speech that did not happen.
    _tts.setCompletionHandler(_noteSpeechFinished);
    _tts.setCancelHandler(_finishUtterance);
    _tts.setErrorHandler((dynamic message) {
      _log('Announcement error: $message');
      _finishUtterance();
    });
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

    // PRE-WARM (section 4.2). Fired here rather than just before the welcome,
    // because firing it next to the thing it is meant to speed up would buy
    // nothing: what it actually buys is the engine loading WHILE the geofence
    // regions below are registered.
    //
    // Not awaited, and it cannot delay the ride: it is queued on the same
    // chain every announcement uses, so the welcome simply follows it.
    unawaited(_preWarmTts());

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

    _log('Planned journey: ${journey.chain.map((s) => s.name).join(' -> ')}');
    for (final interchange in journey.interchanges) {
      _log(
        'Change trains at ${interchange.stationId} onto '
        '${interchange.toLineShortName} towards '
        // The ride log stays English whatever the ride speaks: it is read at
        // a desk, beside English code, by one person.
        '${interchange.towardsStationName.en}'
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
        .nameIn(language);
    final welcomeBody = _copy.welcomeBody(
      origin: journey.chain.first.nameIn(language),
      destination: destinationName,
    );
    // THE GREETING CLIP IS ENGLISH AUDIO, bundled in the APK (it is not part
    // of the pushed pack), so it may only greet an English ride. The other
    // two languages take the TTS path, which speaks the same sentence in the
    // right voice.
    if (sarvamGreeting &&
        Platform.isAndroid &&
        language == AppLanguage.english) {
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
  String _fullWelcome(String welcomeBody) => '${_copy.welcome()} $welcomeBody';

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
      stationName: chain[index].nameIn(_language),
      language: _language,
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
    _pendingClips++;
    _audioChain = _audioChain
        .then((_) async {
          try {
            // THE SESSION, exactly as _speakNow takes it. Clips used to duck
            // only through the audioplayers AudioContext and never touched
            // _session at all, so nothing ever handed the ducking back: on the
            // 13 Aug 2026 ride the owner's music dipped for a clip and stayed
            // quiet for the rest of the journey, unducking once at Kalyan,
            // which is the one clip on that ride whose player failed. Speech
            // was always paired; clips never were.
            //
            // STAMPED FIRST, added 14 Aug 2026. befaca4 took the session here
            // but left the stamp inside _playClipFile, after activation, so an
            // interruption raised by this very line reached the wake engine as
            // a real call. _speakNow has always opened the window before
            // setActive and its comment says why. The stamp inside
            // _playClipFile stays: the two calls cover the two separate
            // moments our own audio can disturb the session.
            _selfInterruption.noteOwnAudioStarted(DateTime.now());
            await _session?.setActive(true);
            _log('CLIP ${clip.uri.pathSegments.last}');
            await _playClipFile(clip);
          } catch (error) {
            _log('CLIP failed, using device TTS: $error');
            // _speakNow, NOT _speak. This code is already running INSIDE
            // _audioChain, and _speak appends to that same chain, so awaiting
            // it here would wait for a future that cannot complete until this
            // one does. One shared queue makes that deadlock possible where
            // two separate queues hid it.
            _pendingSpeaks++;
            await _speakNow(floorText);
          } finally {
            _pendingClips--;
            await _releaseAudioSessionIfIdle();
          }
          // Nothing may escape into the chain itself. A rejected future here
          // poisons every clip queued after it for the rest of the ride, which
          // would silence announcements one by one instead of dropping a single
          // one to the floor.
        })
        .catchError((Object error) {
          _log('CLIP chain error, queue continues: $error');
        });
  }

  /// Plays one clip file through the announcement duck: music dips while
  /// the clip speaks, comes back after, same shape as the greeting slice.
  ///
  /// Throws only when the clip NEVER BECAME SOUND, which is the only case the
  /// caller may answer by speaking the sentence again.
  ///
  /// THE 13 AUG 2026 RIDE MADE THAT DISTINCTION MATTER. Four clips of fourteen
  /// finished playing and then had the identical sentence spoken over the top
  /// of them twelve seconds later, because `onPlayerComplete` never arrived and
  /// the old code read a missing COMPLETION EVENT as a failed CLIP. The rider
  /// heard every one of those announcements twice. A missing event is not a
  /// missing announcement, so the wait now ends quietly and the queue moves on.
  Future<void> _playClipFile(File clip) async {
    final player = ap.AudioPlayer();
    var started = false;
    try {
      await player.setAudioContext(_clipDuckContext);
      // completionOf, NEVER onPlayerComplete raw. See player_completion.dart
      // for the audioplayers type lie this exists to disarm, and for what it
      // cost on the 14 Aug 2026 ride.
      final completed = completionOf(player);
      _selfInterruption.noteOwnAudioStarted(DateTime.now());
      await player.play(ap.DeviceFileSource(clip.path));
      // Past this line the file is playing. Anything that goes wrong now is a
      // bookkeeping problem, never a silent rider.
      started = true;

      // Wait for the clip's OWN length where the platform will report it,
      // rather than a flat twelve seconds for a two second station name. The
      // margin covers the gap between the last sample and the event.
      final duration = await player.getDuration();
      final budget = duration == null
          ? _clipCompletionCap
          : duration + const Duration(seconds: 2);
      await completed.timeout(
        budget < _clipCompletionCap ? budget : _clipCompletionCap,
        onTimeout: () {
          // Quietly. See the note above: the words were heard.
          _log(
            'CLIP completion never arrived after '
            '${budget.inMilliseconds}ms, continuing.',
          );
          return null;
        },
      );
    } catch (error) {
      if (started) {
        // Played, then something failed on the way out. Not worth repeating
        // the sentence over the rider.
        _log('CLIP played but did not close cleanly: $error');
        return;
      }
      rethrow;
    } finally {
      unawaited(player.release());
    }
  }

  /// Ceiling on waiting for a clip to report that it finished. The longest
  /// template runs about 8 s, so this only ever bites when the platform has
  /// stopped answering.
  static const _clipCompletionCap = Duration(seconds: 12);

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
    // THE iOS BLOCK WAS MISSING ENTIRELY UNTIL 14 Aug 2026, and an omitted one
    // is not "leave the session alone": audioplayers substitutes
    // AudioContextIOS(), which is `playback` with NO options, and that is
    // EXCLUSIVE. So every clip interrupted the rider's music and let it resume
    // afterwards, instead of ducking under it, for as long as clips have
    // existed. See duck_audio_context.dart.
    iOS: duckingIosContext,
  );

  /// Plays the bundled greeting clip, then hands over to the normal TTS
  /// welcome. Every failure path falls through to TTS: the clip is an
  /// enhancement and must never cost the rider the route confirmation.
  Future<void> _greetThenSpeak(String welcomeBody) async {
    final player = ap.AudioPlayer();
    var started = false;
    try {
      _log('GREETING clip: welcome_greeting.wav');
      await player.setAudioContext(_clipDuckContext);
      final completed = completionOf(player);
      // STAMPED, and until 14 Aug 2026 this was the one sound in the app that
      // never was. The greeting ducks through _clipDuckContext like any clip,
      // so it can raise the same interruption, and an unstamped one reaches
      // the wake engine as "the rider took a call". Harmless in practice
      // (this plays at ride start, where no ladder exists) and still wrong:
      // the rule is that every sound of ours opens the window before it
      // makes a noise, with no exceptions to remember.
      _selfInterruption.noteOwnAudioStarted(DateTime.now());
      await player.play(ap.AssetSource('audio/welcome_greeting.wav'));
      // Past this line the greeting is sounding.
      started = true;
      // The clip is ~3s; a wedged player must not hold the welcome hostage.
      await completed.timeout(const Duration(seconds: 6));
    } catch (error) {
      if (started) {
        // A MISSING COMPLETION EVENT IS NOT A MISSING GREETING, the same
        // distinction _playClipFile had to learn on 13 Aug 2026. Speaking
        // _fullWelcome here would greet a rider who has just been greeted,
        // and onPlayerComplete failed to arrive for 4 clips of 14 on that
        // ride, so this is not a rare path.
        _log('GREETING clip played but did not close cleanly: $error');
      } else {
        _log('GREETING clip failed, using device TTS: $error');
        await _speak(_fullWelcome(welcomeBody));
        return;
      }
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
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.duckOthers |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.voicePrompt,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
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
    // THE ORDER OF THESE FOUR STEPS IS THE WHOLE FIX, 21 Aug 2026 (evening).
    //
    // Reconfiguring the session UNDER A LIVE UTTERANCE is what kills the iOS
    // synthesizer. The 21 Aug morning ride showed the symptom (an ack
    // mid-sentence silenced the rest of the journey) and the bounded wait
    // added that afternoon rescued the QUEUE but not the SOUND: the bench that
    // evening acked 3.9 s into the check-in, the wait gave up on schedule at
    // 20.0 s, and the very next line, "Good, you are awake", produced no
    // `VOICE started` either. A queue that advances every 20 s in silence is
    // not a working announcer.
    //
    // So: stop the words, THEN move the session, THEN release the waiter.
    // The waiter goes last on purpose. Completing it lets the queue advance,
    // and the next line must not start speaking until the duck profile is back
    // in place, or it walks straight into the reconfigure that just killed
    // this one.
    final waiter = _utteranceDone;
    try {
      if (waiter != null) {
        // Stopping is also the right PRODUCT behaviour, not only the fix. The
        // rider pressed the button. Finishing the sentence that asks them to
        // press the button is nagging someone who already answered.
        try {
          await _tts.stop();
        } catch (error) {
          _log('Could not stop the ladder line: $error');
        }
      }
      await _session?.configure(_duckProfile);
      // Through the shared idle test, which also counts clips. This used to
      // check _pendingSpeaks alone, so a clip playing as the ladder stood down
      // could have the session pulled from under it, or leave it held.
      await _releaseAudioSessionIfIdle();
      _log('WAKE audio: session handed back.');
    } catch (error) {
      _log('Could not restore the announcement audio profile: $error');
    } finally {
      // `identical`, NOT a null check. `_tts.stop()` fires the cancel handler
      // on some platforms, which already released this waiter and let the
      // queue move on to a NEW utterance. Completing blindly here would then
      // cut that innocent next line off before it had spoken a word.
      if (waiter != null && identical(_utteranceDone, waiter)) {
        _log('WAKE audio: ladder line cut short by the ack.');
        _finishUtterance();
      }
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

    // Audio-session interruptions, which mean DIFFERENT THINGS per platform
    // and are handled apart because of it.
    //
    // Android: still the call signal (locked decision 8, on a call means
    // awake), because there is no CallKit and the ringtone genuinely
    // interrupts us.
    // iOS: means we lost audio, nothing more. Calls arrive through CallKit
    // instead. See [_onIosAudioInterruption] for why the proxy was retired.
    //
    // The log lines are load-bearing: replay_ride.dart parses them to
    // reproduce call handling from a real ride's log.
    _interruptionSub = session.interruptionEventStream.listen((event) {
      if (Platform.isIOS) {
        _onIosAudioInterruption(begin: event.begin);
      } else {
        _onAndroidAudioInterruption(begin: event.begin, now: DateTime.now());
      }
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

  /// An audio-session interruption on iOS, where it means WE LOST AUDIO and
  /// nothing else.
  ///
  /// It used to mean "the rider is on a call" (locked decision 8), because the
  /// session was the only call signal we had. It was always a proxy, and a bad
  /// one: an AVAudioSession interruption is raised by a real call, by another
  /// app taking audio, by Siri or a timer, and by our own sounds colliding,
  /// and the session cannot say which. Guessing is what SelfAudioInterruption
  /// Filter existed to do, and on 23 Jul it guessed wrong: the rider started
  /// Music mid-ladder, we recorded it as our own audio, and the ladder went on
  /// logging rungs into silence.
  ///
  /// CallKit reports calls directly now (see [onNativeCallState]), so the
  /// proxy has no job left here and the two facts are separated: calls come
  /// from CallKit, lost audio comes from the session.
  ///
  /// THE POINT OF THE SPLIT is that it makes the classification harmless. The
  /// old response, standing a ladder down, was destructive, so a wrong guess
  /// cost a sleeping rider their alarm. Re-seizing is idempotent: if the sound
  /// was ours we already hold the session and nothing happens, and if another
  /// app took it we take it back. We no longer have to know which it was.
  /// An audio-session interruption on Android, where it IS the call signal
  /// (locked decision 8, on a call means awake). There is no CallKit here and
  /// the ringtone genuinely interrupts us, so this path is unchanged.
  ///
  /// SelfAudioInterruptionFilter stays load-bearing on this platform only: our
  /// own clip colliding with our own speech raises the same event, and feeding
  /// that to the engine stood a live ladder DOWN (21 Jul bench, reproduced
  /// 2 for 2; the 20 Jul Vasind case in the field). Withheld events are still
  /// logged, distinctly, because replay_ride.dart parses these lines and a
  /// silently dropped one would change how old rides replay.
  void _onAndroidAudioInterruption({
    required bool begin,
    required DateTime now,
  }) {
    if (_selfInterruption.shouldIgnore(begin: begin, now: now)) {
      _log(
        begin
            // Says what we KNOW (our own audio was playing, so we withheld
            // it) rather than what we were guessing (that the interruption
            // was ours). On 23 Jul the rider started Music mid-ladder and
            // this line claimed his music was our own audio.
            ? 'Audio session interrupted while our own audio played, withheld.'
            : 'Audio session interruption ended (withheld).',
      );
      return;
    }
    _log(
      begin
          ? 'Audio session interrupted (call or other audio).'
          : 'Audio session interruption ended.',
    );
    // Same door as CallKit, for the same reason: on Android the interruption
    // IS the call signal, so one ending while the rider has the alarm switched
    // off must not resume it either.
    _inRealCall = begin;
    _syncWakeSuspension(now);
  }

  /// WORDING IS LOAD-BEARING. These lines must not read like the Android call
  /// lines, because replay_ride.dart parses those and would otherwise replay a
  /// lost-audio recovery as a call, inventing a hang-up catch-up that never
  /// happened. In particular this must never emit the bare
  /// "Audio session interruption ended." that the Android branch uses.
  ///
  /// RECOVERY IS DELIBERATELY LEFT TO THE ~5 s TICK, not done here. The tick
  /// already re-asserts the tone while a ladder is live, and startTone now
  /// re-seizes the session, so audio comes back within one tick either way.
  /// Doing it here as well would be worse than redundant: a REAL call raises
  /// this interruption too, and CallKit's stand-down arrives a moment later,
  /// so an immediate re-seize would restart the alarm into a ringing call and
  /// only then be told to stop. Waiting a tick lets CallKit win that race, and
  /// once a ladder has stood down there is no tone volume left to re-assert.
  void _onIosAudioInterruption({required bool begin}) {
    if (!begin) {
      _log('Audio regained (iOS interruption ended).');
      return;
    }
    _log(
      _wakeToneVolume == null
          // Nothing of ours is sounding, so there is nothing to rescue.
          // Announcements are one-shot and the next one activates the session
          // for itself.
          ? 'Audio lost (iOS interruption), nothing sounding.'
          : 'Audio lost (iOS interruption) with a ladder live, '
                'the tone watchdog will re-seize.',
    );
  }

  /// iOS CallKit call state, arriving from the main isolate. On iOS this is
  /// now the ONLY thing that tells the wake engine about a call.
  ///
  /// The audio session used to do it, and could not: it sees a call only while
  /// it is active, which on iOS means only while we happen to be making noise.
  /// The 23 Jul bench answered a real call in silence and the app logged
  /// nothing at all. CallKit reports calls whoever owns audio.
  ///
  /// It also cannot be fooled the way the session could. A session
  /// interruption is raised by calls, by other apps, by Siri and by our own
  /// sounds alike; CallKit reports calls and only calls, so the rider starting
  /// Music can never again read as "the rider is on a call".
  void onNativeCallState(bool inCall) {
    // Load-bearing, like the interruption lines: a ride log has to show which
    // signal moved the ladder, or a later session cannot tell a CallKit
    // suspension from a session one.
    _log(inCall ? 'Call started (CallKit).' : 'Call ended (CallKit).');
    _handlePulseActions(
      _pocketPulse?.onCallState(inCall, DateTime.now()) ?? const [],
    );
    // Through the one authority, never straight at the engine: see
    // [_syncWakeSuspension] for the alarm this stops re-arming.
    _inRealCall = inCall;
    _syncWakeSuspension(DateTime.now());
  }

  /// What the iOS audio session did when the alarm asked for it, arriving from
  /// the main isolate the same way the CallKit state does.
  ///
  /// Records whether the alarm is actually SOUNDING, which no line in this log
  /// could say before 24 Jul. A refused seizure went to NSLog, which a
  /// sideloaded build never shows, so a ladder climbing in silence wrote
  /// exactly the same lines as one the rider could hear: on 24 Jul seven rungs
  /// at full volume were logged into nothing. "exclusive" also means the
  /// earphone tap can reach us; "ducked" means the rider's music kept the
  /// buttons and only the on-screen button will ack.
  ///
  /// iOS only. Android's tone runs through audioplayers, which reports its own
  /// failures on the Dart side already.
  void onNativeAudioNote(String note) {
    _log('WAKE audio: $note.');
  }

  /// Speaks [text], ducking other audio only for the duration of the speech.
  ///
  /// Calls are serialized on one chain, so a fix arriving mid-announcement
  /// queues behind it rather than cutting it off. The session is deactivated
  /// only once the last queued announcement has finished, so a run of them (the
  /// Thane approach ping followed by the interchange script) ducks the music
  /// once rather than bobbing its volume between sentences.
  /// Releases whatever utterance is waiting. Idempotent and safe to call when
  /// nothing is speaking: a cancel and a completion can both arrive for the
  /// same utterance, and a double completion would throw.
  void _finishUtterance() {
    final done = _utteranceDone;
    _utteranceDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// When the pending utterance was handed to the engine, so [_noteSpeechStarted]
  /// can say how long it took to become sound.
  DateTime? _spokenAt;

  /// When the engine actually started making noise, so [_noteSpeechFinished]
  /// can say how long the sentence took to speak.
  DateTime? _voiceStartedAt;

  /// Whether the current utterance's 20 s wait already gave up.
  ///
  /// THE BENCH THIS EXISTS FOR, 16 Aug 2026: the welcome timed out at exactly
  /// 20.0 s on the 3T with clips off, and the log could not say whether the
  /// engine was still speaking or the completion event was lost. Those need
  /// opposite fixes (a longer wait, or not waiting on that event at all), and
  /// the difference was invisible because a late completion is dropped in
  /// silence. Now it is not.
  bool _utteranceTimedOut = false;

  /// The engine has started making noise. Logs decision-to-voice latency,
  /// which is the number section 4.2 sets a one second budget for and the one
  /// no ride has ever reported.
  void _noteSpeechStarted() {
    final at = _spokenAt;
    if (at == null) return;
    _spokenAt = null;
    final now = DateTime.now();
    _voiceStartedAt = now;
    _log('VOICE started ${now.difference(at).inMilliseconds}ms after the call');
  }

  /// The engine reached the end of the sentence. Logs how long it spoke, and
  /// says so explicitly when the 20 s wait had already given up on it.
  void _noteSpeechFinished() {
    final at = _voiceStartedAt;
    _voiceStartedAt = null;
    final lateBy = _utteranceTimedOut ? ', after the wait gave up' : '';
    _utteranceTimedOut = false;
    if (at != null) {
      _log(
        'VOICE finished after '
        '${DateTime.now().difference(at).inMilliseconds}ms of speech$lateBy',
      );
    }
    _finishUtterance();
  }

  Future<void> _speak(String text) {
    _pendingSpeaks++;
    _audioChain = _audioChain.then((_) => _speakNow(text));
    return _audioChain;
  }

  /// Speaks one line WITHOUT queueing it. Callers already inside [_audioChain]
  /// use this; everyone else uses [_speak]. The caller owns the matching
  /// `_pendingSpeaks++`.
  Future<void> _speakNow(String text) async {
    {
      try {
        // Activating the session is itself one half of the collision, so the
        // window opens here rather than after the utterance starts.
        _selfInterruption.noteOwnAudioStarted(DateTime.now());
        await _session?.setActive(true);
        // Wait for the ENGINE to say it has finished, not for speak() to
        // return, because under QUEUE_ADD those are not the same moment and
        // the difference is the whole ducking bug. Bounded: the longest
        // interchange script runs about 8 s at rate 0.45 and the welcome about
        // 14 s, and a TTS engine that never reports completion must not wedge
        // every later announcement of the ride behind it.
        //
        // BOTH PLATFORMS SINCE 21 AUG 2026, and iOS is the one that needed it.
        // The wait used to be Android-only, on the reasoning that iOS honours
        // awaitSpeakCompletion and could simply be awaited. It does, until the
        // utterance is killed rather than finished: on the 21 Aug ride the
        // rider acked the Kalyan ladder MID-SENTENCE, standing it down
        // reconfigured the audio session under a live AVSpeechSynthesizer, and
        // iOS fired neither didFinish nor didCancel. The speak() future never
        // completed, so `_audioChain` wedged and `_pendingSpeaks` stuck at 1.
        // Every announcement for the remaining nine minutes of the ride was
        // queued and never spoken: the arrival at the destination, the
        // wind-down, and the farewell. The log's only trace was one line,
        // `PULSE slot abandoned: announcer busy 60s`.
        final done = Completer<void>();
        _utteranceDone = done;
        _spokenAt = DateTime.now();
        _utteranceTimedOut = false;
        if (Platform.isAndroid) {
          await _tts.speak(text);
        } else {
          // NOT AWAITED ON iOS, and that is the fix rather than an oversight.
          // With awaitSpeakCompletion(true) this future resolves from the same
          // didFinish/didCancel that feed `done`, so awaiting it adds nothing
          // the completer does not already give us, and it is precisely what
          // hangs when neither callback fires. The timeout below can only
          // rescue the chain if nothing upstream of it can block forever.
          unawaited(
            _tts.speak(text).catchError((Object error) {
              _log('Announcement failed: $error');
              _finishUtterance();
              return 0;
            }),
          );
        }
        await done.future.timeout(
          // 30, NOT 20, RAISED 21 Aug 2026 BY A FALSE POSITIVE ON THE 3T.
          // The Titwala welcome spoke for 19186 ms and the 20 s bound fired
          // 400 ms before the engine's own completion arrived. Nothing was
          // wrong: the sentence is simply that long at rate 0.45. A wait that
          // gives up on a HEALTHY utterance releases the audio session while
          // the words are still coming out, which is the 30 Jul 2026 duck bug
          // wearing a new hat. The bound exists for an engine that has died,
          // and 30 s clears the longest real line by a comfortable margin.
          const Duration(seconds: 30),
          onTimeout: () {
            _log('Announcement completion never arrived, continuing.');
            _utteranceTimedOut = true;
            if (identical(_utteranceDone, done)) _utteranceDone = null;
          },
        );
      } catch (error) {
        // Swallowed so one failed announcement cannot poison the chain and
        // silence every announcement after it for the rest of the ride.
        _log('Announcement failed: $error');
        // Release the waiter too. Swallowing the error kept the CHAIN alive
        // but left a completer that no callback will ever complete, which is
        // the same wedge by a slower route.
        _finishUtterance();
      } finally {
        _pendingSpeaks--;
        await _releaseAudioSessionIfIdle();
      }
    }
  }

  /// Hands the audio session back once NOTHING of ours is making noise.
  ///
  /// The rule itself lives in [audioSessionIsIdle], with the evidence for each
  /// of its four terms: two rides (clips, 13 Aug 2026; the pulse chime,
  /// 14 Aug) and one bench (the ladder, 15 Jul). Speech cost nothing, because
  /// speech has always released what it activated.
  ///
  /// It is a free function so that it can have real tests: this service cannot
  /// be built under the test binding, so anything decided in here can only
  /// ever be guarded from source.
  Future<void> _releaseAudioSessionIfIdle() async {
    if (!audioSessionIsIdle(
      pendingSpeaks: _pendingSpeaks,
      pendingClips: _pendingClips,
      pendingPulses: _pendingPulses,
      wakeLadderLive: _wakeLadderLive,
    )) {
      return;
    }
    await _session?.setActive(false);
  }

  /// Loads the TTS engine before the ride needs it, by speaking one silent
  /// space (handover section 4.2).
  ///
  /// WHAT THIS IS AND IS NOT WORTH. The engine's cold start is a real cost,
  /// but the app already pays it during the WELCOME line, which speaks seconds
  /// into every ride. So no station announcement was ever the cold one, which
  /// is the likeliest reason no ride log has shown a latency problem. What
  /// this buys is the welcome itself, and the [_noteSpeechStarted] instrument
  /// added beside it is what will say on the next ride whether that was worth
  /// having. If it was not, this method is a two line deletion.
  ///
  /// IT GOES THROUGH [_speak], deliberately. Calling `_tts.speak` directly
  /// would skip the audio-session discipline every other utterance obeys, and
  /// inside the plugin that call activates the session: doing it raw at ride
  /// start is exactly the shape of the 13 Jul bench bug, where Travel Mode
  /// grabbed audio focus the moment it began.
  ///
  /// The volume is dropped and restored ON THE SAME CHAIN, so the restore
  /// cannot land after the welcome has been queued. Getting that ordering
  /// wrong would speak the welcome at volume zero, which is a silent first
  /// impression on the one line that proves the audio path works at all.
  Future<void> _preWarmTts() {
    final startedAt = DateTime.now();
    _audioChain = _audioChain.then((_) => _tts.setVolume(0));
    unawaited(_speak(' '));
    _audioChain = _audioChain.then((_) async {
      await _tts.setVolume(1);
      _log(
        'TTS pre-warm done in '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
    });
    return _audioChain;
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
      final text = ClipKind.approach.render(
        origin.nameIn(_language),
        language: _language,
      );
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
    await _speak(_copy.testAnnouncement());
  }

  /// The rider changed the pulse interval MID-RIDE, from Settings.
  ///
  /// Re-anchors from now, so a rider switching crowd mode on hears the tighter
  /// cadence start immediately rather than after the old interval drains. The
  /// UI rewrites the store key in the same breath, so a service restarted after
  /// this reads the new value rather than the one the ride started with.
  void setPulseInterval(int? seconds) {
    _handlePulseActions(
      _pocketPulse?.setInterval(seconds, DateTime.now()) ?? const [],
    );
  }

  /// Debug-only, and it is THE BENCH INSTRUMENT for Pocket Pulse.
  ///
  /// Section 7 of docs/design/pocket-pulse.md asks for the audio risk to be
  /// spiked at the desk BEFORE the engine is built, a carve-out made 29 Jul
  /// that had slipped twice. This is what makes that possible: no engine, no
  /// timer, no settings, just the real chime through the real duck.
  ///
  /// [collideAfterMs] is bench item 2, and it is the one that matters. Firing
  /// a chime a few hundred milliseconds into a spoken line reproduces the
  /// 21 Jul collision, where our own audio raised an interruption that the
  /// service reads as "the rider took a call" and the wake ladder STOOD DOWN
  /// on a sleeping rider. With the stamp in PulseOutput the ride log should
  /// show the interruption attributed to our own audio and the ladder
  /// untouched. Without it, this is how we would find out on a train.
  Future<void> testPulse({int? collideAfterMs}) async {
    final output = _pulseOutput;
    if (output == null) {
      _log('PULSE test ignored: no ride is running.');
      return;
    }
    if (collideAfterMs == null) {
      _log('PULSE test chime.');
      await _chimeThroughSession(output);
      await output.buzz();
      return;
    }
    // A SWEEP, not a single offset, and the first run of this bench is why.
    // Firing one chime 150 ms after _speak() returns proved nothing: TTS takes
    // longer than that to produce sound, so the chime had come and gone before
    // any speech began and the "no interruption" result was untestable. The
    // sweep walks the chime across the whole utterance, so at least one lands
    // during session activation, one mid-sentence, and one at the tail.
    const offsets = [150, 700, 1500, 2500, 3500];
    _log('PULSE collision sweep: chimes at ${offsets.join(", ")} ms.');
    unawaited(
      _speak(
        'This is a long test announcement for the pocket pulse collision '
        'bench, and it needs to keep speaking for several seconds so that a '
        'chime can land in the middle of it more than once.',
      ),
    );
    var elapsed = 0;
    for (final at in offsets) {
      await Future<void>.delayed(Duration(milliseconds: at - elapsed));
      elapsed = at;
      _log('PULSE collision chime at ${at}ms.');
      await _chimeThroughSession(output);
    }
  }

  /// One chime, through the same audio-session discipline speech and clips
  /// obey. THE ONLY WAY THE SERVICE MAY SOUND A CHIME.
  ///
  /// Calling [PulseOutput.chime] directly is the 14 Aug 2026 bug: the chime
  /// ducks the rider's music through its own AudioContext, and on iOS that
  /// context is the app-wide shared AVAudioSession, so without a matching
  /// release the music stays down until something else happens to speak. The
  /// rider heard exactly that, every 45 s, for a whole leg.
  ///
  /// The counter is what makes the release safe rather than merely present: a
  /// chime that finishes while an announcement is still speaking must not pull
  /// the session out from under it, which is the same trap
  /// [_releaseAudioSessionIfIdle] was widened for on 13 Aug.
  Future<void> _chimeThroughSession(PulseOutput output) async {
    _pendingPulses++;
    try {
      // STAMPED BEFORE setActive, NOT AFTER, and this order is the whole
      // reason the 21 Jul 2026 bug is not back. Activating the session is
      // itself one half of the collision: it can raise an audio interruption,
      // the service feeds interruptions to the wake engine as "the rider took
      // a call", and SelfAudioInterruptionFilter's window only ever measures
      // FORWARD from the stamp. So an interruption raised by this line with
      // the stamp still to come is attributed to the rider, not to us.
      //
      // PulseOutput.chime stamps again just before play(), which is correct
      // and not redundant: the two calls open the window at the two separate
      // moments our own audio can disturb the session.
      //
      // _speakNow has always done it in this order and says so in its own
      // comment. The chime did not, because until today it never took the
      // session at all.
      _selfInterruption.noteOwnAudioStarted(DateTime.now());
      await _session?.setActive(true);
      await output.chime();
    } catch (error) {
      // NOT DEAD CODE, though it looks it: PulseOutput.chime is written to
      // swallow its own failures, so setActive(true) is the only thing that
      // SHOULD throw here. "Should" rather than "can": the output is
      // injected, and nothing enforces that contract on a double or on a
      // future rewrite.
      //
      // The setActive failure is real and observed, not theoretical. The
      // 14 Aug 2026 bench logged "Could not restore the announcement audio
      // profile: PlatformException(560557684)" when iOS refused the session
      // while another app held it, which is the same refusal (CannotInterrupt
      // Others) the wake ladder meets. A pulse must lose that argument
      // quietly.
      _log('PULSE chime failed: $error');
    } finally {
      // THE finally IS WHAT CARRIES THE FIX. A chime that threw on the way in
      // must still give the music back, or one refused session leaves the
      // rider's music ducked for the rest of the ride.
      _pendingPulses--;
      await _releaseAudioSessionIfIdle();
    }
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
    _wakeTestCeiling = targetIndex + 1 < chain.length
        ? chain[targetIndex + 1]
        : null;
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

  /// Whether every station is spoken, or only the ones the rider must act on.
  ///
  /// Read once at Start from the store, like the language, because a ride
  /// should not change its voice halfway through.
  bool _announceEveryStation = true;

  /// What "only your stop" is still allowed to say, and every one of these is
  /// a station the rider has to DO something at.
  ///
  /// The row's own copy is the specification: "Off announces only your stop,
  /// and still wakes you." So:
  ///
  ///   - THE DESTINATION, which is the stop.
  ///   - AN INTERCHANGE, because a rider who misses one is as stranded as a
  ///     rider who misses their stop, and this switch is about commentary
  ///     rather than about instructions.
  ///   - AN OVERSHOOT, which is the safety net for the failure this whole
  ///     product exists to prevent. It is never optional.
  ///
  /// What goes quiet is the running commentary on stations the rider passes
  /// through, which is the only thing the switch was ever meant to turn off.
  /// The wake ladder is untouched: it is a separate engine with its own toggle.
  bool _mustAlwaysSpeak(Announcement announcement) {
    if (announcement.kind == AnnouncementKind.overshoot) return true;
    final journey = _journey;
    if (journey == null) return true;
    if (announcement.stationId == journey.destinationStationId) return true;
    return journey.interchanges.any(
      (interchange) => interchange.stationId == announcement.stationId,
    );
  }

  /// Whether the rider wants to be woken ON THIS RIDE.
  ///
  /// True unless they say otherwise, and deliberately NOT a setting: it resets
  /// at every Start, because a remembered "off" is how somebody misses their
  /// stop in October having switched it off in August. The service only lives
  /// as long as the ride, so the reset is by construction.
  ///
  /// It exists because the ladder fires whether or not the rider is asleep, so
  /// an awake rider on a short hop had to acknowledge an escalating alarm every
  /// journey. That is not safety, it is a chore, and a chore is what teaches
  /// somebody to ignore the one thing this product sells.
  ///
  /// IT DOES NOT TOUCH ANNOUNCEMENTS. They come from RideProgress and are the
  /// rest of the product; the overshoot net still speaks too. Wake off means
  /// the alarm is off, not the ride.
  bool _wakeEnabled = true;

  /// Whether a real call is in progress, tracked separately from [_wakeEnabled]
  /// because both suspend the ladder and only one of them may resume it.
  bool _inRealCall = false;

  /// What we last told the engine, so the two inputs above cannot double-send.
  bool _wakeSuspended = false;

  /// THE ONE PLACE THAT SUSPENDS OR RESUMES THE LADDER, and the reason it
  /// exists is a bug it makes impossible.
  ///
  /// A real call and the rider's wake toggle both suspend through
  /// `WakeEscalation.onCallStateChanged`, which is the right mechanism: silent,
  /// but not deaf, and re-orienting on the way back. Wired naively, they share
  /// one flag, so a call ENDING while the alarm was switched off would resume
  /// the ladder and re-arm the alarm the rider had deliberately turned off.
  /// That is silent-alarm class in reverse: an alarm nobody asked for, on a
  /// rider who is awake and now trusts the app less.
  ///
  /// So suspension is the OR of the two, resume happens only when both agree,
  /// and neither caller talks to the engine directly.
  void _syncWakeSuspension(DateTime now) {
    // THE RULE ITSELF LIVES IN [WakeSuspension], in its own file, because this
    // class cannot be built in a test and that rule is the half worth testing.
    final next = WakeSuspension.of(
      inRealCall: _inRealCall,
      wakeEnabled: _wakeEnabled,
    );
    if (next.suspended == _wakeSuspended) return;
    _wakeSuspended = next.suspended;
    _handleWakeActions(
      _wakeEscalation?.onCallStateChanged(
            inCall: next.suspended,
            now: now,
            catchUp: next.catchUp,
          ) ??
          const [],
    );
  }

  /// The rider turned the alarm off, or back on, mid-ride.
  void setWakeEnabled(bool enabled) {
    if (_wakeEnabled == enabled) return;
    _wakeEnabled = enabled;
    _log('WAKE ${enabled ? 'armed' : 'DISARMED'} by the rider for this ride.');
    _syncWakeSuspension(DateTime.now());
  }

  /// An acknowledgment from outside the service isolate: the earphone tap
  /// (native media session, forwarded by the UI isolate) or the on-screen
  /// "I'm awake" button.
  /// [source] names which path acked so the log file can tell an earphone tap
  /// from the on-screen button. Logged BEFORE the engine is asked, so a tap
  /// that arrives when no ladder is live still leaves a trace.
  void wakeAck({String? source}) {
    _log('WAKE ack from ${source ?? 'unknown'}.');
    // Only an ack that answers a LIVE ladder counts as the rider being woken.
    // A tap when nothing is sounding is a tap.
    if (_wakeLadderLive) _wakeAnsweredThisRide = true;
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
        case WakeNote(:final message):
          // Log only. The engine uses this to record a decision that makes NO
          // sound, which is the only kind a ride log cannot otherwise show.
          _log(message);
        case Speak(:final text):
          _log('WAKE speak: $text');
          unawaited(_speak(text));
        case Tone(:final volume):
          _log('WAKE tone ${volume.toStringAsFixed(1)}.');
          _wakeToneVolume = volume;
          // The alarm loop is our own audio for as long as it runs. Without
          // this the tone's own contention comes back as "the rider took a
          // call" and stands the ladder down mid-climb, which is exactly how
          // the 22 Jul iPhone leg went 0.3 -> 0.6 -> silence, twice, into the
          // rider's destination. The clip and speak paths were already
          // covered; the tone never was, on either platform.
          _selfInterruption.noteSustainedOwnAudioStarted(DateTime.now());
          unawaited(_wakeOutput?.ensureToneAt(volume));
        case StopTone():
          _wakeToneVolume = null;
          _selfInterruption.noteSustainedOwnAudioEnded();
          unawaited(_wakeOutput?.stopTone());
        case Vibrate():
          // NOT awaited, and on iOS that now matters: the burst holds the
          // future open for 800 ms while it spaces its buzzes, and the rest
          // of this ladder's actions must not queue behind a vibration.
          unawaited(_wakeOutput?.vibrate());
        case HardStop():
          _log('WAKE hard stop: ceiling reached, ladder given up.');
          _wakeToneVolume = null;
          // The engine always pairs StopTone with HardStop when a tone was
          // playing, so this clear is redundant today. It stays because the
          // cost of the two disagreeing one day is a flag stuck up for the
          // rest of the ride, and clearing twice costs nothing.
          _selfInterruption.noteSustainedOwnAudioEnded();
          unawaited(_wakeOutput?.stopTone());
      }
    }

    final live = _wakeEscalation?.isLadderLive ?? false;
    final rung = _wakeEscalation?.rung ?? 0;
    // THE RUNG IS PART OF THE CHANGE, not just liveness. The wake alert screen
    // steps its glow with the sound, and a ladder that climbs from rung 1 to 3
    // never changes `live`, so anything keyed on liveness alone would hold the
    // quietest glow through the loudest alarm. Same shape as the wind-down
    // deadline: the flag is not the state.
    if (live != _wakeLadderLive || rung != _wakeLadderRung) {
      final changedLive = live != _wakeLadderLive;
      _wakeLadderLive = live;
      _wakeLadderRung = rung;
      // Remembered for the whole ride: wake success is measured over the rides
      // where the alarm actually had to work, and a ride the rider slept
      // through cannot be told from one they stayed awake for without this.
      if (live) _wakeArmedThisRide = true;
      if (changedLive) {
        _log('WAKE ladder ${live ? 'live' : 'stood down'}.');
        if (!live) {
          _wakeTestCeilingAt = null;
          _wakeTestCeiling = null;
          // Second belt on the iOS burst. WakeAlertOutput.stopTone already
          // cancels it, and every stand-down the engine can reach today pairs
          // with a StopTone, but an ack inside the check-in window emits none
          // (there is no tone yet to stop). Nothing emits Vibrate that early
          // now; if anything ever does, the failure would be a burst buzzing
          // at a rider who has already said they are awake, which is the one
          // outcome this feature must never produce.
          _wakeOutput?.cancelVibration();
          unawaited(_releaseLadderAudio());
        }
        // Pocket Pulse DROPS while a ladder is live, and does not catch up when
        // it stands down. Fed from here rather than sniffed from a flag so the
        // two can never disagree about whether an alarm is sounding.
        _handlePulseActions(
          _pocketPulse?.onWakeLadder(live, DateTime.now()) ?? const [],
        );
      }
      onWakeLadderLive?.call(live, rung, _wakeEscalation?.isClimbing ?? true);
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
    final destination = journey.chain.firstWhere(
      (s) => s.id == journey.destinationStationId,
    );
    final now = DateTime.now();
    // The arrival itself, which the real path fires beside the announcement.
    // Without it this bench skipped straight to the countdown and never
    // exercised what a rider gets first: Screen 5 opens on the ARRIVAL, minutes
    // before any countdown exists.
    onDestinationReached?.call();
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
    // Then a WALK, simulated as a walk rather than as a teleport.
    //
    // THIS BENCH COULD NOT START A COUNTDOWN, and had not been able to since
    // the teleport guard landed: it jumped ~700 m with one second between
    // fixes, and WindDown rejects any displacement above `2.5 * elapsed` as a
    // GPS jump rather than a walk (the 20 Jul lone 6.2 m/s reading). So the
    // button armed the exit watch and stopped, and every countdown state below
    // it was unreachable from the desk. Found 4 Aug 2026 while wiring Screen 5,
    // by reading the ride log instead of the screen.
    //
    // 2 m/s, a fix every 10 s: inside the 12 s continuity gap so the streak
    // never breaks and the anchor is never re-set, past 150 m by 80 s, and far
    // under the 4 m/s recession that would disarm this as a departing train.
    for (var i = 1; i <= 9; i++) {
      final walkedM = 20.0 * i;
      _handleWindDownActions(
        windDown.onFix(
          lat: destination.lat + walkedM / 111000.0,
          lng: destination.lng,
          accuracyM: 10,
          speedMps: 2.0,
          now: now.add(Duration(seconds: 10 * i)),
        ),
      );
    }
  }

  /// Ends the ride. [reason] is written to the ride log before the farewell.
  ///
  /// The farewell line is byte-identical whether the app decided to end or
  /// the rider held the button, and on the 22 Jul ride that ambiguity had me
  /// read two manual ends as a slow auto-off and report a wind-down tail that
  /// never existed. A log that records outcomes but not causes cannot be
  /// audited. Same lesson as the wake ack source (bb19b39) and the wind-down
  /// notes: say WHY, at the moment it happens.
  ///
  /// [reason] is required on purpose. A default would let a future call site
  /// produce exactly the unauditable "the ride ended, no idea why" line this
  /// parameter was added to abolish.
  Future<void> stop({required String reason}) async {
    _log('Journey ending: $reason.');
    // Sent FIRST, before the teardown below clears the state it describes, and
    // not awaited: a slow or unreachable analytics endpoint must never hold up
    // the end of a ride. Silent and cost-free when the rider has opted out or
    // no key is compiled in.
    unawaited(
      _analytics.trackRideEnded(
        outcome: _rideOutcome,
        wakeArmed: _wakeArmedThisRide,
        wakeAnswered: _wakeAnsweredThisRide,
      ),
    );
    // The engine dies first so nothing re-starts the tone mid-teardown; a
    // ride ended mid-ladder must also release the UI's media session.
    _wakeEscalation = null;
    _wakeTestCeilingAt = null;
    _wakeTestCeiling = null;
    _wakeToneVolume = null;
    // stop() tears the tone down directly rather than through a StopTone
    // action, so the sustained flag has to be cleared by hand here. A flag
    // left set would outlive the ride and make the NEXT one ignore a real
    // call, which is the one failure mode this whole filter must not cause.
    _selfInterruption.noteSustainedOwnAudioEnded();
    await _wakeOutput?.stopTone();
    await _wakeOutput?.dispose();
    _wakeOutput = null;
    _pulseOutput = null;
    _pocketPulse = null;
    if (_wakeLadderLive) {
      _wakeLadderLive = false;
      _wakeLadderRung = 0;
      onWakeLadderLive?.call(false, 0, true);
    }

    // A manual End mid-countdown must not leave phantom wind-down buttons.
    _windDown = null;
    _rideTimeout = null;
    _rideHealth = null;
    // The next ride starts with no opinion about where its rider gets off.
    _alightStationId = null;
    if (_windDownLive) {
      _windDownLive = false;
      _windDownEndsAt = null;
      onWindDownLive?.call(false, null, WindDown.countdown);
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
    final farewell = FixedLine.farewell.render(language: _language);
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
    // Reset with the engine it tracks. A second ride on a service that already
    // ran one would otherwise inherit a high water mark and never publish its
    // early stations, which is the same shape as the sustained-flag leak.
    _lastPublishedIndex = -1;
    _lastPublishedAtStation = false;
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
    final dir = Platform.isAndroid ? await getExternalStorageDirectory() : null;
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
    final announcements =
        _rideProgress?.onFix(
          lat: location.latitude,
          lng: location.longitude,
          accuracyM: location.accuracy,
        ) ??
        const <Announcement>[];

    // ONE definition of "usable", RideProgress's own accuracy ceiling, read off
    // the engine rather than copied. A second copy of that number here would
    // drift the day it is tuned, and the two would disagree about whether the
    // stream is healthy while the chain refused to move.
    _handleHealthActions(
      _rideHealth?.onFix(
            DateTime.now(),
            usable: location.accuracy <= (_rideProgress?.maxAccuracyM ?? 150),
            lat: location.latitude,
            lng: location.longitude,
          ) ??
          const [],
    );

    // Position, published on CHANGE only. Sits here rather than inside the
    // announcement loop because the chain can advance without speaking (a
    // catch-up that resolves to a station already announced), and Screen 4 must
    // still move.
    // AT the station or PAST it travels with the index, because it changes
    // without the index changing: a train sits in Vithalwadi for a minute and
    // then leaves, and reachedIndex is the same number throughout. Publishing
    // on the index alone would freeze the screen on whichever of the two
    // states happened to be true when the train arrived.
    final reached = _rideProgress?.reachedIndex;
    final atStation = _rideProgress?.atReachedStation ?? false;
    if (reached != null &&
        (reached != _lastPublishedIndex ||
            atStation != _lastPublishedAtStation)) {
      _lastPublishedIndex = reached;
      _lastPublishedAtStation = atStation;
      onProgress?.call(reached, atStation);
    }

    final now = DateTime.now();
    for (final announcement in announcements) {
      // The SPEAK line's format is load-bearing: replay_ride.dart parses it.
      _log(
        'SPEAK ${announcement.kind.name} ${announcement.stationId}: '
        '${announcement.text}',
      );
      // THE VOICE IS WITHHELD, NEVER THE EVENT, and that distinction is the
      // whole of this feature. WakeEscalation reads these same announcements to
      // know where the train is, WindDown reads them to know the ride arrived,
      // and RideProgress ratchets on them. Suppressing the ANNOUNCEMENT rather
      // than the speech would silence the alarm along with the commentary,
      // which is the exact opposite of what the row promises.
      //
      // The SPEAK line stays and a second line records the withholding, the
      // same shape the audio-interruption path already uses: replay_ride.dart
      // parses SPEAK lines to reconstruct a ride, and a dropped one would
      // change how old logs replay.
      if (!_announceEveryStation && !_mustAlwaysSpeak(announcement)) {
        _log('SPEAK withheld: announce-every-station is off.');
      } else {
        final clip = _clipForAnnouncement(announcement);
        if (clip != null) {
          _enqueueClip(clip, floorText: announcement.text);
        } else {
          unawaited(_speak(announcement.text));
        }
      }

      if (announcement.kind == AnnouncementKind.arrival &&
          announcement.stationId == _journey?.destinationStationId) {
        _destinationAnnounced = true;
        onDestinationReached?.call();
      }
      // The failure the whole product exists to prevent, and the one outcome
      // that must never be lost in an "ended early" bucket.
      if (announcement.kind == AnnouncementKind.overshoot) _overshot = true;

      _handleWindDownActions(
        _windDown?.onStationEvent(announcement, now) ?? const [],
      );
      _handleWakeActions(
        _wakeEscalation?.onStationEvent(announcement, now) ?? const [],
      );
      // The ride is provably moving. Approach and arrival for one station are
      // both crossings here; the engine drops the near-zero segment between
      // them rather than letting it drag the median down.
      //
      // The two facts it cannot work out for itself come from the JOURNEY, and
      // both were found by replaying the six real logs through it: an
      // interchange is an eighteen minute gap that is not a stall (18 Jul,
      // Thane), and after the destination or an overshoot pin there are no more
      // stations to cross at all (22 Jul, walking home from Shahad).
      final journey = _journey;
      _handleHealthActions(
        _rideHealth?.onStationPassed(
              now,
              stationId: announcement.stationId,
              changeHere:
                  journey?.interchanges.any(
                    (i) => i.stationId == announcement.stationId,
                  ) ??
                  false,
              endsWatch:
                  announcement.kind == AnnouncementKind.overshoot ||
                  (announcement.kind == AnnouncementKind.arrival &&
                      announcement.stationId == journey?.destinationStationId),
            ) ??
            const [],
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
  /// Writes the phone's thermal state into the ride log, on change only.
  ///
  /// FIRE AND FORGET, never awaited: the tick drives the wake ladder, the
  /// pulse and the wind-down, and an instrument may not stand in front of any
  /// of them. A reading that arrives late is still a reading; a tick that
  /// waits for one is a ride that stutters.
  ///
  /// See ThermalGateway for why this number is worth a line in the log at all.
  void _noteThermalState(DateTime now) {
    final askedAt = _thermalAskedAt;
    if (askedAt != null && now.difference(askedAt) < _thermalInterval) return;
    _thermalAskedAt = now;
    unawaited(
      _thermal.read().then((state) {
        if (state == null || state == _lastThermal) return;
        final from = _lastThermal;
        _lastThermal = state;
        _log(
          from == null
              ? 'THERMAL ${state.name}'
              : 'THERMAL ${from.name} -> ${state.name}',
        );
      }),
    );
  }

  void onTick(DateTime now) {
    _noteThermalState(now);

    _handleWindDownActions(_windDown?.onTick(now) ?? const []);

    _handleHealthActions(_rideHealth?.onTick(now) ?? const []);

    _handleTimeoutActions(
      _rideTimeout?.onTick(
            now,
            wakeLadderLive: _wakeEscalation?.isLadderLive ?? false,
            windDownLive: _windDownLive,
          ) ??
          const [],
    );

    // Pocket Pulse rides the tick the other engines already use. `announcerBusy`
    // is passed rather than held, because it is a fact about right now: TTS
    // queued or speaking, or a clip queued or playing.
    _handlePulseActions(
      _pocketPulse?.onTick(
            now,
            announcerBusy: _pendingSpeaks > 0 || _pendingClips > 0,
          ) ??
          const [],
    );

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

  /// Turns the pulse engine's decisions into sound and log lines.
  ///
  /// Fire and forget: a chime that fails is a chime that is missed, and must
  /// never be able to disturb the ride that asked for it.
  void _handlePulseActions(List<PulseAction> actions) {
    final output = _pulseOutput;
    for (final action in actions) {
      switch (action) {
        case PulseChime():
          if (output == null) continue;
          // LOGGED, despite being the most frequent event in a ride. A 45 s
          // crowd-mode ride writes about 120 of these into a file that already
          // holds thousands of FIX lines, and without them a rider reporting
          // "the pulse stopped" leaves nothing to read. Same rule the rest of
          // this service follows: silence has no cause in a log.
          _log('PULSE chime.');
          unawaited(_chimeThroughSession(output));
          if (_pulseVibrate) unawaited(output.buzz());
        case PulseNote(:final reason):
          // Uppercase prefix, like every other line in this file. The engine
          // writes "pulse suppressed: ..." in prose; the log wants "PULSE ...".
          // Ride logs are read under pressure and a lowercase outlier is the
          // line the eye skips.
          _log(
            reason.startsWith('pulse ')
                ? 'PULSE ${reason.substring(6)}'
                : 'PULSE $reason',
          );
      }
    }
  }

  /// GPS_LOST and STALL. Notices, so the only thing that ever happens here is a
  /// sentence and a log line.
  void _handleHealthActions(List<RideHealthAction> actions) {
    for (final action in actions) {
      switch (action) {
        case RideHealthSpeak(:final text):
          unawaited(_speak(text));
        case RideHealthNote(:final reason):
          _log('HEALTH $reason.');
      }
    }
  }

  /// The four-hour backstop's actions. It ends the ride down the SAME path the
  /// wind-down auto-off uses, so there is one teardown, not two.
  void _handleTimeoutActions(List<RideTimeoutAction> actions) {
    for (final action in actions) {
      switch (action) {
        case RideTimeoutSpeak(:final text):
          _log('TIMEOUT speaking the four-hour warning.');
          unawaited(_speak(text));
        case RideTimeoutEnd():
          _log('TIMEOUT ending Travel Mode.');
          _timedOut = true;
          onAutoOff?.call();
        case RideTimeoutNote(:final reason):
          _log('TIMEOUT $reason.');
      }
    }
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
        case WindDownNote(:final reason):
          _log('WIND_DOWN $reason.');
      }
    }
    // Where the rider is getting off, published on change. It is set to the
    // destination when WindDown is built and moves exactly once, at an
    // overshoot pin, so on a ride that goes to plan this fires once at the
    // start and never again.
    final alight = _windDown?.alightStationId;
    if (alight != null && alight != _alightStationId) {
      final moved = _alightStationId != null;
      _alightStationId = alight;
      if (moved) {
        _log('WIND_DOWN alighting at $alight now, not the stop picked.');
      }
      onAlightingAt?.call(alight);
    }

    // Mirrors the countdown state out to the notification buttons, the debug
    // screen and Screen 5, only on change.
    //
    // THE DEADLINE IS PART OF THE CHANGE, not just liveness: Extend replaces
    // the deadline while live stays true, and a rider who pressed it must see
    // the ten minutes they asked for.
    final live = _windDown?.isCountingDown ?? false;
    final endsAt = _windDown?.endsAt;
    if (live != _windDownLive || endsAt != _windDownEndsAt) {
      final started = live != _windDownLive;
      _windDownLive = live;
      _windDownEndsAt = endsAt;
      if (started) {
        _log('WIND_DOWN countdown ${live ? 'started' : 'stopped'}.');
      }
      onWindDownLive?.call(
        live,
        endsAt,
        _windDown?.window ?? WindDown.countdown,
      );
    }
  }

  void _onRawLocationError(Object error, StackTrace stackTrace) {
    _log('Raw location stream error: $error');
  }

  void _onGeofenceError(Object error, StackTrace stackTrace) {
    _log('Geofencing error: $error');
  }

  /// How this ride finished, in the four words analytics is allowed to know.
  ///
  /// ORDER MATTERS. An overshoot outranks an arrival because a ride can do
  /// both: the destination is announced, the rider sleeps through it, and the
  /// pin fires a stop later. Reporting that as "arrived" would count the
  /// product's central failure as its central success, and the wake success
  /// bar would read 100 percent on a ride that missed the stop.
  RideOutcome get _rideOutcome {
    if (_overshot) return RideOutcome.overshot;
    if (_destinationAnnounced) return RideOutcome.arrived;
    if (_timedOut) return RideOutcome.timeout;
    return RideOutcome.endedEarly;
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
