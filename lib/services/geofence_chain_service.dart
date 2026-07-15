import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geofencing_api/geofencing_api.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/station_repository.dart';
import '../models/journey.dart';
import 'ride_progress.dart';
import 'wake_alert_spike.dart';

/// Runs one ride, between any two stations on the network.
///
/// Given the rider's origin and destination, [JourneyPlanner] works out the
/// chain, the interchanges and the overshoot pin; this registers a geofence per
/// station on that chain (plus a second, larger outer approach fence for each
/// interchange and the destination), speaks an announcement as the ride passes
/// each one, and logs every event so accuracy can be judged from a real ride.
class GeofenceChainService {
  GeofenceChainService({
    required this.onLog,
    this.onDestinationReached,
    this.onRawFix,
    this.onWakeLadderLive,
  });

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

  Journey? _journey;

  final FlutterTts _tts = FlutterTts();
  RideProgress? _rideProgress;
  WakeAlertSpike? _wakeSpike;
  File? _logFile;
  StreamSubscription<fl.Location>? _rawLocationSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  AudioSession? _session;

  /// Serializes announcements so two never overlap, and so the ducking window
  /// spans a whole run of them (see [_speak]).
  Future<void> _speaking = Future<void>.value();
  int _pendingSpeaks = 0;

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
      approachRadiusM: journey.approachRadiusM,
      arrivalAnnouncements: journey.arrivalAnnouncements,
    );
    _wakeSpike = WakeAlertSpike(
      speak: _speak,
      log: _log,
      onLiveChanged: (live) {
        _wakeLadderLive = live;
        if (!live) {
          unawaited(_releaseLadderAudio());
        }
        onWakeLadderLive?.call(live);
      },
    );

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
    for (final station in journey.chain) {
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
    final welcome =
        'Welcome to Commute Guardian. Travel Mode is on, from '
        '${journey.chain.first.name} to $destinationName. I will announce '
        'each station along the way. To end the journey at any time, press '
        'and hold the End journey button.';
    _log('SPEAK welcome: $welcome');
    unawaited(_speak(welcome));
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

    // Diagnostics only. Reclaiming the session after a call is no longer needed
    // now that every announcement activates it for itself.
    _interruptionSub = session.interruptionEventStream.listen((event) {
      _log(
        event.begin
            ? 'Audio session interrupted (call or other audio).'
            : 'Audio session interruption ended.',
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
    await _speak(
      'This is a test announcement from Commute Guardian. '
      'If you can hear this, text to speech is working.',
    );
  }

  /// Debug-only: runs the W1 spike ladder end to end, exactly as a missed
  /// check-in would, so the tone, the ramp and the earphone-tap ack can be
  /// benched on a locked phone without riding a train.
  Future<void> testWakeAlert() async {
    _log('WAKE test requested.');
    await _wakeSpike?.start();
  }

  /// An acknowledgment from outside the service isolate: the earphone tap
  /// (native media session, forwarded by the UI isolate) or the on-screen
  /// "I'm awake" button.
  void wakeAck() {
    _wakeSpike?.acknowledge();
  }

  Future<void> stop() async {
    await _wakeSpike?.dispose();
    _wakeSpike = null;

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
    for (final announcement in announcements) {
      _log(
        'SPEAK ${announcement.kind.name} ${announcement.stationId}: '
        '${announcement.text}',
      );
      unawaited(_speak(announcement.text));

      if (announcement.kind == AnnouncementKind.arrival &&
          announcement.stationId == _journey?.destinationStationId) {
        onDestinationReached?.call();
      }
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
