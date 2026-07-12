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

/// Runs one ride, between any two stations on the network.
///
/// Given the rider's origin and destination, [JourneyPlanner] works out the
/// chain, the interchanges and the overshoot pin; this registers a geofence per
/// station on that chain (plus a second, larger outer approach fence for each
/// interchange and the destination), speaks an announcement as the ride passes
/// each one, and logs every event so accuracy can be judged from a real ride.
class GeofenceChainService {
  GeofenceChainService({required this.onLog});

  /// Marks the outer approach fence for a two-stage station, keeping its
  /// region id distinct from the inner station fence.
  static const _approachSuffix = '#approach';

  final void Function(String message) onLog;

  Journey? _journey;

  final FlutterTts _tts = FlutterTts();
  RideProgress? _rideProgress;
  File? _logFile;
  StreamSubscription<fl.Location>? _rawLocationSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  AudioSession? _session;

  /// Serializes announcements so two never overlap, and so the ducking window
  /// spans a whole run of them (see [_speak]).
  Future<void> _speaking = Future<void>.value();
  int _pendingSpeaks = 0;

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
        '${interchange.toLineShortName}'
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
  }

  /// Configures a ducking spoken-audio session, but deliberately does NOT
  /// activate it: [_speak] activates only for as long as it is actually
  /// speaking. Holding the session active for the whole ride is what caused the
  /// 12 Jul field bug, where a podcast already playing when Travel Mode started
  /// was ducked and then stayed quiet for the rest of the journey.
  Future<void> _configureAudio() async {
    final session = await AudioSession.instance;
    _session = session;
    await session.configure(
      const AudioSessionConfiguration.speech().copyWith(
        // `speech()` on its own is EXCLUSIVE on iOS (category playback with no
        // options): activating it over a podcast interrupts the podcast rather
        // than ducking it. Duck + mix makes announcements ride over other audio.
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.duckOthers |
                AVAudioSessionCategoryOptions.mixWithOthers,
        // What actually tells the other app to come back to full volume when we
        // deactivate at the end of an announcement.
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
        // `speech()` asks Android for AUDIOFOCUS_GAIN (permanent), which tells a
        // music app to stop outright and never hands focus back. Transient
        // may-duck is what a navigation prompt takes.
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.assistanceNavigationGuidance,
        ),
        // We are the one doing the ducking, so we must not duck ourselves.
        androidWillPauseWhenDucked: false,
      ),
    );

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
      // instead of standing up a second one of its own.
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
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
        if (_pendingSpeaks == 0) {
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

  Future<void> stop() async {
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
    final station = _journey?.chain.firstWhere((s) => s.id == stationId);
    if (station == null) {
      return;
    }

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
