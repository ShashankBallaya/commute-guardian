import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../foreground/geofence_task_handler.dart';
import '../models/app_settings.dart';
import 'wind_down.dart';

/// One thing that happened on the other side of the isolate boundary.
///
/// The service isolate sends untyped maps (see [GeofenceTaskHandler]); these
/// are what those maps mean. Parsing lives in [parseServiceData], which is
/// pure and therefore testable without a plugin.
sealed class ServiceEvent {
  const ServiceEvent();
}

/// A line for the debug log. Either echoed from the ride log by the service,
/// or generated on this side by the client for something only the UI can see
/// (a media button arriving, a native call failing).
class ServiceLogged extends ServiceEvent {
  const ServiceLogged(this.message);
  final String message;
}

/// The wake ladder started or finished asking to be acknowledged.
class WakeLadderChanged extends ServiceEvent {
  const WakeLadderChanged(this.live, {this.rung = 0, this.climbing = true});
  final bool live;

  /// Which rung the ladder is on, 1-based, 0 when nothing is live. Drives the
  /// alert screen's glow, which steps with the sound.
  final int rung;

  /// False once the ladder is at full volume and holding.
  final bool climbing;
}

/// The post-arrival auto-off countdown started or stopped.
class WindDownChanged extends ServiceEvent {
  const WindDownChanged(
    this.live, {
    this.endsAt,
    this.window = WindDown.countdown,
  });
  final bool live;

  /// When Travel Mode ends by itself, null when nothing is counting. Screen 5
  /// shows this to the rider, so it travels rather than being guessed.
  final DateTime? endsAt;

  /// The window [endsAt] was set from: 60 s normally, 10 minutes after Extend.
  final Duration window;
}

/// The service asked for one short vibration. iOS ONLY, and a BENCH: Android
/// buzzes inside the service isolate with the vibration package and needs no
/// hop at all. See AppDelegate's "vibrate" case for what is being tested.
class VibrateCommanded extends ServiceEvent {
  const VibrateCommanded();
}

/// iOS only: play or stop the ladder tone natively. audioplayers' loop dies
/// under the seized session, so AppDelegate owns the tone there.
class ToneCommanded extends ServiceEvent {
  const ToneCommanded(this.command, this.volume);
  final String command;
  final double volume;
}

/// The ride reached a further station along the chain. Screen 4 is drawn from
/// this, and it comes from the service's own RideProgress so the chain has one
/// projector rather than two that can disagree.
class RideProgressed extends ServiceEvent {
  const RideProgressed(this.reachedIndex, {this.atStation = false});

  /// Index into the journey chain, or -1 before the first station.
  final int reachedIndex;

  /// Standing IN that station rather than past it. Fires again with the same
  /// [reachedIndex] when the train pulls out, which is the whole point: the
  /// index does not change when a train leaves a platform.
  final bool atStation;
}

/// The ride reached the destination and said so out loud.
///
/// Distinct from [RideProgressed] hitting the last index: the arrival is what
/// the announcement commits to, and it is what arms WindDown. Screen 5 opens on
/// this.
class DestinationReached extends ServiceEvent {
  const DestinationReached();
}

/// Where the rider is going to get off, which after an overshoot is NOT the
/// station they picked.
///
/// Fires once at the start of every ride (naming the destination) and again
/// only if the rider is carried past it to an overshoot pin. It is its own
/// event rather than a field on [WindDownChanged] because that move changes
/// neither liveness nor the deadline, so anything keyed to those would never
/// hear it.
class AlightingAt extends ServiceEvent {
  const AlightingAt(this.stationId);
  final String stationId;
}

/// The service ended the ride on its own (wind-down auto-off).
class RideEndedByService extends ServiceEvent {
  const RideEndedByService();
}

/// A GPS fix the service saw. Keeps the "You're near" chip live mid-ride.
class ServiceFix extends ServiceEvent {
  const ServiceFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
  });
  final double lat;
  final double lng;
  final double accuracyM;
}

/// What the service isolate persisted about the ride it is running.
///
/// This, not any widget's state, is the truth about a live ride: it is what
/// the service itself read at start. Android recreated the activity mid-ride
/// on 15 Jul and the rebuilt screen showed a blank destination because the UI
/// never asked.
class PersistedRide {
  const PersistedRide({
    required this.originId,
    required this.destinationId,
    required this.destinationReached,
    this.reachedIndex = -1,
    this.atStation = false,
    this.startedAt,
    this.startBatteryPct,
    this.wakeLadderLive = false,
    this.wakeRung = 0,
    this.wakeClimbing = true,
    this.windDownLive = false,
    this.windDownEndsAt,
    this.windDownWindow = WindDown.countdown,
    this.alightStationId,
  });

  /// When the ride started, or null if no ride is running. The history row is
  /// assembled from here rather than from widget state, so swiping the app out
  /// of recents does not cost the journey its record.
  final DateTime? startedAt;

  /// Battery at ride start, or null when the platform would not say.
  final int? startBatteryPct;

  final String? originId;
  final String? destinationId;

  /// How far along the chain the ride has provably got, or -1 before the first
  /// station. Screen 4 draws itself from this after a process recreation, for
  /// the same reason the destination is read here rather than held in a widget.
  final int reachedIndex;

  /// Standing IN the station at [reachedIndex]. Read back after a process
  /// recreation so a rebuilt Screen 4 draws the platform the rider is on
  /// rather than the gap after it.
  final bool atStation;

  /// True only once the destination arrival announcement actually spoke. An
  /// early End stays false, which is what gates the turnaround origin default
  /// and the history row's reachedDestination.
  final bool destinationReached;

  /// Whether the wake ladder is asking to be acknowledged right now, and
  /// whether the auto-off countdown is running. Read back so a UI that was
  /// recreated or reopened knows an alert it never saw start is still live.
  final bool wakeLadderLive;

  /// The live ladder's rung and whether it is still climbing, read back so a UI
  /// born mid-alarm shows the glow the sound has already reached.
  final int wakeRung;
  final bool wakeClimbing;

  final bool windDownLive;

  /// The live countdown's deadline and the window it was set from. Read back
  /// so Screen 5, born after a process recreation, shows the seconds the rider
  /// really has left rather than a fresh minute it invented.
  final DateTime? windDownEndsAt;
  final Duration windDownWindow;

  /// The station the rider will get off at, or null for the destination they
  /// picked. It differs only after an overshoot, and it is read back here for
  /// the same reason the deadline is: Screen 5 may be opened by a process that
  /// was recreated after the pin was reached.
  final String? alightStationId;
}

/// Turns one raw payload from the service isolate into the events it carries.
///
/// A single payload can carry several (a fix plus a log line), so this returns
/// a list. Pure on purpose: the parsing is the part worth testing, and it must
/// be testable with no plugin, no isolate and no device.
List<ServiceEvent> parseServiceData(Object data) {
  if (data is! Map<String, dynamic>) return const [];
  final events = <ServiceEvent>[];

  final message = data['message'] as String?;
  if (message != null) events.add(ServiceLogged(message));

  final ladderLive = data['wakeLadderLive'] as bool?;
  if (ladderLive != null) {
    events.add(
      WakeLadderChanged(
        ladderLive,
        rung: (data['wakeRung'] as num?)?.toInt() ?? 0,
        climbing: data['wakeClimbing'] as bool? ?? true,
      ),
    );
  }

  final windDownLive = data['windDownLive'] as bool?;
  if (windDownLive != null) {
    final endsAtMs = (data['windDownEndsAtMs'] as num?)?.toInt();
    final windowS = (data['windDownWindowS'] as num?)?.toInt();
    events.add(
      WindDownChanged(
        windDownLive,
        // Absent or zero both mean "nothing is counting". Zero is what the
        // store holds for none, because saveData has no null.
        endsAt: (endsAtMs == null || endsAtMs == 0)
            ? null
            : DateTime.fromMillisecondsSinceEpoch(endsAtMs),
        window: windowS == null
            ? WindDown.countdown
            : Duration(seconds: windowS),
      ),
    );
  }

  final reachedIndex = (data['reachedIndex'] as num?)?.toInt();
  if (reachedIndex != null) {
    events.add(
      RideProgressed(
        reachedIndex,
        atStation: data['atStation'] as bool? ?? false,
      ),
    );
  }

  final toneCommand = data['toneCommand'] as String?;
  if (toneCommand != null) {
    events.add(
      ToneCommanded(
        toneCommand,
        (data['toneVolume'] as num?)?.toDouble() ?? 1.0,
      ),
    );
  }

  if (data['vibrate'] == true) {
    events.add(const VibrateCommanded());
  }

  if (data['destinationReached'] == true) {
    events.add(const DestinationReached());
  }

  final alightStationId = data['alightStationId'] as String?;
  if (alightStationId != null && alightStationId.isNotEmpty) {
    events.add(AlightingAt(alightStationId));
  }

  if (data['rideEnded'] == true) events.add(const RideEndedByService());

  final lat = (data['fixLat'] as num?)?.toDouble();
  final lng = (data['fixLng'] as num?)?.toDouble();
  final accuracyM = (data['fixAccuracyM'] as num?)?.toDouble();
  if (lat != null && lng != null && accuracyM != null) {
    events.add(ServiceFix(lat: lat, lng: lng, accuracyM: accuracyM));
  }

  return events;
}

/// The UI isolate's one and only door to the service isolate.
///
/// NOTHING else in lib/ outside lib/foreground/ may import
/// flutter_foreground_task or touch the media-ack MethodChannel; a test
/// enforces that (test/isolate_boundary_test.dart). The point is not tidiness.
/// Commands here are FIRE AND FORGET across an isolate boundary, and a design
/// that quietly assumes otherwise fails only on a locked phone in a pocket,
/// which is where every hard bug in this project has lived.
///
/// See docs/design/riverpod-adoption.md. This class deliberately holds no
/// Riverpod: the provider that owns it comes later and owns nothing else.
class RideServiceClient {
  RideServiceClient();

  /// Must run before [runApp], so the isolate port exists when the service
  /// starts sending.
  static void initCommunicationPort() =>
      FlutterForegroundTask.initCommunicationPort();

  /// Carries the wake ladder's earphone-tap acknowledgment. Native side: a
  /// MediaSessionCompat in MainActivity (Android) and MPRemoteCommandCenter in
  /// the AppDelegate (iOS), activated only while a ladder is live so this app
  /// owns media buttons exactly when a tap means "I'm awake" and never longer.
  /// Lives in the UI isolate because that is the engine the native side is
  /// attached to; the ack is forwarded to the service isolate over the same
  /// seam the test buttons use. Best-effort by design: if the OS has killed the
  /// backgrounded activity the tap is lost, and the escalation plus the manual
  /// dismiss remain the guaranteed fallback.
  ///
  /// The channel name must stay byte-identical to the one the native side
  /// registers. A typo here is invisible to every test and breaks the earphone
  /// ack only on a real device.
  static const _mediaAckChannel = MethodChannel('commute_guardian/media_ack');

  final _events = StreamController<ServiceEvent>.broadcast();

  /// Everything arriving from the service isolate, plus the client's own
  /// notes about native calls the UI would otherwise never see.
  Stream<ServiceEvent> get events => _events.stream;

  void _emit(ServiceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Subscribes to the service isolate and to native media buttons, and
  /// configures the foreground service. Call once, from initState.
  void start() {
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _mediaAckChannel.setMethodCallHandler(_onMediaAck);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'geofence_chain',
        channelName: 'Travel Mode',
        channelDescription: 'Announces stations while Travel Mode is active.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        // ON since 11 Aug 2026, and it had been off since the day the onboarding
        // panel started promising "while a journey runs we keep one notification
        // up. It is how you end a ride or keep tracking a little longer without
        // unlocking the phone." On iOS that was untrue.
        //
        // IT IS NOT MAINLY ABOUT VISIBILITY. The plugin builds real
        // UNNotificationActions from the same buttons this app already sets
        // (BackgroundService.swift setNotificationActions, reading
        // notificationContent.buttons), so turning this on gives iOS the
        // "I'm awake", "End now" and "Extend 10 min" controls it has never had.
        // That is an acknowledgement route which does not need the audio session
        // held exclusively (the 24 Jul finding) and does not die with the UI (the
        // 30 Jul swipe bench). It is the only ack an iPhone has if the rider's
        // music is playing and their earphone tap goes to the music app.
        //
        // HONEST LIMIT: this is not Android's ongoing notification. iOS has no
        // such thing. The rider can swipe it away, and it cannot stop a swipe
        // from the app switcher killing the ride, because iOS terminates the
        // process (confirmed on device 11 Aug, and in the plugin's
        // applicationWillTerminate, which is a shutdown hook with a five second
        // grace). A Live Activity is the real answer and needs a widget
        // extension target; it is Phase 3 work.
        showNotification: true,
        // Stays false. This app already speaks, and the wake ladder owns
        // escalation. A notification chime on top of the ladder would be a
        // second, quieter alarm competing with the one designed to wake people.
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _mediaAckChannel.setMethodCallHandler(null);
    unawaited(_events.close());
  }

  void _onReceiveTaskData(Object data) {
    for (final event in parseServiceData(data)) {
      _emit(event);
    }
  }

  // ---------------------------------------------------------------------
  // Events in: native media buttons and call state
  // ---------------------------------------------------------------------

  Future<dynamic> _onMediaAck(MethodCall call) async {
    if (call.method == 'ack') {
      // iOS forwards which remote command fired (the double-tap maps to
      // different ones across earbuds); Android sends none. It travels WITH
      // the ack so the service writes it to the ride log: the 21 Jul bench
      // proved the on-screen list alone is not evidence, because a rider
      // watching the road never sees it.
      final via = call.arguments is String ? call.arguments as String : '';
      FlutterForegroundTask.sendDataToTask('$wakeAckMediaPrefix$via');
      _emit(
        ServiceLogged(
          'Media button received${via.isEmpty ? '' : ' via $via'}, '
          'ack forwarded to service.',
        ),
      );
    }
    if (call.method == 'callState') {
      // iOS only, from CXCallObserver. The audio session cannot see a call
      // that arrives while we are silent (23 Jul bench: a real answered call
      // logged nothing at all), so this is the only signal decision 8 has on
      // iPhone outside our own announcements.
      final inCall = call.arguments == true;
      FlutterForegroundTask.sendDataToTask('$wakeCallStatePrefix$inCall');
      _emit(
        ServiceLogged(
          'Native call state: ${inCall ? 'on a call' : 'call ended'}, '
          'forwarded to service.',
        ),
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Commands out
  // ---------------------------------------------------------------------

  /// Claims (or releases) media-button routing natively. Held only while a
  /// ladder is live: outside that window the rider's earphone taps must keep
  /// controlling their music, not us.
  Future<void> setMediaSession(bool active) async {
    try {
      final note = await _mediaAckChannel.invokeMethod<String>(
        active ? 'startSession' : 'stopSession',
      );
      _forwardAudioNote(note);
    } catch (error) {
      _emit(
        ServiceLogged(
          'Media session ${active ? 'start' : 'stop'} failed: $error',
        ),
      );
    }
  }

  /// How loud the wake alarm will actually be, 0.0 to 1.0, or null when the
  /// platform will not say.
  ///
  /// FAILS OPEN, like every other pre-flight probe: null shows the rider
  /// nothing rather than a warning we cannot stand behind. A false alarm before
  /// every ride teaches them to tap past Screen 3 on the ride where it mattered.
  ///
  /// THE TWO PLATFORMS MEASURE DIFFERENT THINGS, deliberately. Android reads
  /// STREAM_ALARM, because the tone is played with alarm usage and the rider's
  /// media slider cannot touch it. iOS has no alarm stream, so it reads
  /// outputVolume, which IS what the ladder gets there. Flattening them into
  /// one abstract "volume" would mean reporting a number that is wrong on one
  /// of the two platforms.
  ///
  /// Lives here rather than on [AudioOutputGateway] because it needs the native
  /// channel, and this is the one file allowed to hold it.
  Future<double?> alarmVolume() async {
    try {
      final value = await _mediaAckChannel
          .invokeMethod<double>('getAlarmVolume')
          .timeout(const Duration(seconds: 2));
      if (value == null || value.isNaN || value < 0) return null;
      return value.clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  /// One short system vibration, iOS only, and it is a BENCH not a feature yet.
  ///
  /// Rides the same service-to-main-to-native hop the ladder tone uses, because
  /// the service isolate cannot reach a channel registered on the main engine
  /// (learned the hard way earlier today with the volume probe).
  Future<void> sendNativeVibrate() async {
    try {
      await _mediaAckChannel.invokeMethod<void>('vibrate');
    } catch (error) {
      _emit(ServiceLogged('Native vibrate failed: $error'));
    }
  }

  /// Drives the native ladder tone, and carries back what the audio session
  /// did about it.
  Future<void> sendNativeTone(String command, double volume) async {
    try {
      final note = await _mediaAckChannel.invokeMethod<String>(command, volume);
      _forwardAudioNote(note);
    } catch (error) {
      _emit(ServiceLogged('Native tone $command failed: $error'));
    }
  }

  /// Puts an iOS audio-session note into the RIDE LOG, by handing it to the
  /// service isolate that owns the file.
  ///
  /// The debug screen alone is not enough and the 21 Jul benches proved it: a
  /// rider with the phone in a pocket sees nothing, so anything that matters
  /// has to reach the file. Native returns null when there was nothing worth
  /// recording, which is most ticks.
  void _forwardAudioNote(String? note) {
    if (note == null || note.isEmpty) return;
    FlutterForegroundTask.sendDataToTask('$wakeAudioNotePrefix$note');
    _emit(ServiceLogged('Audio session: $note'));
  }

  void ackWakeFromButton() =>
      FlutterForegroundTask.sendDataToTask(wakeAckButtonId);
  void windDownEndNow() =>
      FlutterForegroundTask.sendDataToTask(windDownEndNowId);
  void windDownExtend() =>
      FlutterForegroundTask.sendDataToTask(windDownExtendId);
  void testTts() => FlutterForegroundTask.sendDataToTask('test_tts');
  void testWakeAlert() =>
      FlutterForegroundTask.sendDataToTask('test_wake_alert');
  void testWindDown() => FlutterForegroundTask.sendDataToTask('test_wind_down');

  /// The rider changed the pulse interval while a ride is running.
  ///
  /// DUAL WRITE, deliberately. The message updates the engine that is running
  /// right now; the store is what a restarted service reads. Sending only the
  /// message would lose the change on a restart, and writing only the store
  /// would leave the running ride on the old cadence until it ended.
  Future<void> setPulseInterval({required int? seconds, bool? vibrate}) async {
    await FlutterForegroundTask.saveData(
      key: pulseIntervalKey,
      value: seconds ?? 0,
    );
    if (vibrate != null) {
      await FlutterForegroundTask.saveData(
        key: pulseVibrateKey,
        value: vibrate,
      );
    }
    FlutterForegroundTask.sendDataToTask(
      '$pulseSetPrefix${seconds == null || seconds <= 0 ? 'off' : seconds}',
    );
  }

  /// The rider's wake toggle on Screen 4, for THIS ride only.
  ///
  /// Sent, never saved. Every other setting on that screen writes to the store
  /// as well as sending, so a restarted service picks it up mid-ride; this one
  /// must not, because it resets to armed at every Start and a stored "off"
  /// would outlive the journey it was meant for.
  void setWakeEnabled(bool enabled) =>
      FlutterForegroundTask.sendDataToTask('$wakeEnabledPrefix$enabled');

  /// Pocket Pulse bench, section 7 of docs/design/pocket-pulse.md.
  void testPulse() => FlutterForegroundTask.sendDataToTask('test_pulse');
  void testPulseCollision({int afterMs = 150}) =>
      FlutterForegroundTask.sendDataToTask('$pulseCollidePrefix$afterMs');

  // ---------------------------------------------------------------------
  // Lifecycle and the shared store
  // ---------------------------------------------------------------------

  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  /// Everything the store knows about the running ride. Safe to call when no
  /// ride is running: the ids come back null.
  Future<PersistedRide> readPersistedRide() async => PersistedRide(
    originId: await FlutterForegroundTask.getData<String>(key: originIdKey),
    destinationId: await FlutterForegroundTask.getData<String>(
      key: destinationIdKey,
    ),
    destinationReached:
        await FlutterForegroundTask.getData<bool>(key: destinationReachedKey) ??
        false,
    reachedIndex:
        await FlutterForegroundTask.getData<int>(key: reachedIndexKey) ?? -1,
    atStation:
        await FlutterForegroundTask.getData<bool>(key: atStationKey) ?? false,
    startedAt: _dateFromMillis(
      await FlutterForegroundTask.getData<int>(key: rideStartedAtKey),
    ),
    startBatteryPct: _batteryFromStore(
      await FlutterForegroundTask.getData<int>(key: rideStartBatteryKey),
    ),
    wakeLadderLive:
        await FlutterForegroundTask.getData<bool>(key: wakeLadderLiveKey) ??
        false,
    wakeRung: await FlutterForegroundTask.getData<int>(key: wakeRungKey) ?? 0,
    wakeClimbing:
        await FlutterForegroundTask.getData<bool>(key: wakeClimbingKey) ?? true,
    windDownLive:
        await FlutterForegroundTask.getData<bool>(key: windDownLiveKey) ??
        false,
    windDownEndsAt: _dateFromMillis(
      await FlutterForegroundTask.getData<int>(key: windDownEndsAtKey),
    ),
    windDownWindow: Duration(
      seconds:
          await FlutterForegroundTask.getData<int>(key: windDownWindowKey) ??
          WindDown.countdown.inSeconds,
    ),
    alightStationId: _stationFromStore(
      await FlutterForegroundTask.getData<String>(key: alightStationKey),
    ),
  );

  static DateTime? _dateFromMillis(int? millis) => millis == null || millis <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis);

  /// -1 is the store's way of saying the platform would not give a reading.
  static int? _batteryFromStore(int? pct) =>
      pct == null || pct < 0 ? null : pct;

  /// Empty is the store's way of saying "no opinion", since saveData has no
  /// null. Null here means the destination, which is where a ride that goes to
  /// plan ends.
  static String? _stationFromStore(String? id) =>
      id == null || id.isEmpty ? null : id;

  /// Clears the history row's seed once the row is written, so a later read
  /// cannot resurrect a journey that has already been recorded.
  Future<void> clearRideRecordSeed() async {
    await FlutterForegroundTask.saveData(key: rideStartedAtKey, value: 0);
    await FlutterForegroundTask.saveData(key: rideStartBatteryKey, value: -1);
  }

  Future<void> requestBatteryOptimizationExemption() async {
    if (Platform.isAndroid &&
        !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  /// Hands the ride over through the shared store, then starts the service.
  ///
  /// The journey crosses as IDS, never as an object: the service isolate has
  /// its own heap and its own planner, and replans from these two ids exactly
  /// as it always has.
  Future<bool> startRide({
    required String originStationId,
    required String destinationStationId,
    required String notificationText,
    required bool sarvamGreeting,
    required bool sarvamClips,
    required DateTime startedAt,
    int? startBatteryPct,
    // Pocket Pulse's settings, handed over HERE and not only on change. The
    // first build shipped the mid-ride push alone, and the interval never
    // reached a ride that simply started with the pulse already switched on:
    // the store key was written only when a ride was already running.
    int? pulseIntervalSeconds,
    bool pulseVibrate = true,
    // Read at START like the pulse settings, and for the same reason: a
    // setting that only crosses on change never reaches a ride that simply
    // began with it already set. Defaults to OFF so a caller that forgets it
    // sends nothing rather than sending without consent.
    bool shareAnonymousUsage = false,
    bool announceEveryStation = true,
    // Same rule again: read at START, not only on change. Unlike the pulse
    // interval this one has no mid-ride push at all, on purpose. Every engine
    // renders its sentences from the language it was constructed with and the
    // clip pack is opened from one directory, so a ride keeps the voice it
    // began in and a rider who switches language hears it on the next ride.
    AppLanguage language = AppLanguage.english,
  }) async {
    await FlutterForegroundTask.saveData(
      key: originIdKey,
      value: originStationId,
    );
    await FlutterForegroundTask.saveData(
      key: destinationIdKey,
      value: destinationStationId,
    );
    // Armed false here, set true by the service when the destination arrival
    // actually speaks. Gates the turnaround default in _defaultOriginToRideEnd.
    await FlutterForegroundTask.saveData(
      key: destinationReachedKey,
      value: false,
    );
    // The history row's seed, stored beside the ride rather than held in a
    // widget, so a journey survives the app being swiped out of recents with
    // its record intact. -1 means "the platform would not say".
    await FlutterForegroundTask.saveData(
      key: rideStartedAtKey,
      value: startedAt.millisecondsSinceEpoch,
    );
    await FlutterForegroundTask.saveData(
      key: rideStartBatteryKey,
      value: startBatteryPct ?? -1,
    );
    await FlutterForegroundTask.saveData(
      key: sarvamGreetingKey,
      value: sarvamGreeting,
    );
    await FlutterForegroundTask.saveData(
      key: sarvamClipsKey,
      value: sarvamClips,
    );
    await FlutterForegroundTask.saveData(
      key: pulseIntervalKey,
      value: pulseIntervalSeconds ?? 0,
    );
    await FlutterForegroundTask.saveData(
      key: pulseVibrateKey,
      value: pulseVibrate,
    );
    await FlutterForegroundTask.saveData(
      key: shareUsageKey,
      value: shareAnonymousUsage,
    );
    await FlutterForegroundTask.saveData(key: languageKey, value: language.tag);
    await FlutterForegroundTask.saveData(
      key: announceEveryStationServiceKey,
      value: announceEveryStation,
    );
    // Measured HERE and not in the service, which cannot reach the channel that
    // answers. -1 means the platform would not say, because the store holds
    // primitives and a null would be indistinguishable from an absent key on a
    // service the OS recreated mid-ride.
    await FlutterForegroundTask.saveData(
      key: alarmVolumeKey,
      value: await alarmVolume() ?? -1.0,
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: 1,
      notificationTitle: 'Travel Mode active',
      notificationText: notificationText,
      callback: geofenceTaskStartCallback,
    );
    return result is ServiceRequestSuccess;
  }

  Future<void> stopRide() => FlutterForegroundTask.stopService();
}
