import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/app_settings.dart';
import '../services/analytics.dart';
import '../services/crash_reporting.dart';
import '../services/geofence_chain_service.dart';

/// Entry point the foreground service isolate calls to install the handler.
/// Must stay top-level (or static) per flutter_foreground_task's contract.
@pragma('vm:entry-point')
void geofenceTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(GeofenceTaskHandler());
}

/// Keys the picked ride is passed under. The service runs in its OWN isolate with
/// its own heap, so it cannot read the picker's state directly; these are written
/// by the UI before the service starts and read back here. See
/// [FlutterForegroundTask.saveData].
const originIdKey = 'origin_station_id';
const destinationIdKey = 'destination_station_id';

/// Debug bench flag: play the bundled Sarvam greeting clip at Start (Android
/// only). Written by the debug screen's toggle, read once at service start.
const sarvamGreetingKey = 'sarvam_greeting';

/// Debug bench flag, clip slice 2: station announcements play as full-phrase
/// Sarvam clips from the pushed pack (Android only), device TTS otherwise.
const sarvamClipsKey = 'sarvam_clips';

/// Whether the CURRENT ride announced arrival at its destination. Written false
/// by the UI at Start, true by the service on arrival, read back by the UI at
/// Stop to decide if the turnaround origin default can be trusted.
const destinationReachedKey = 'destination_reached';

/// How far along the chain the ride has provably got. Saved as well as sent,
/// so a UI the OS recreated mid-ride draws Screen 4 correctly with no user
/// action, the way the destination already survives that.
const reachedIndexKey = 'reached_index';

/// Whether the train is standing IN the station at [reachedIndexKey] rather
/// than somewhere past it. Travels beside the index because it changes while
/// the index does not: see `GeofenceChainService.onProgress`.
const atStationKey = 'at_station';

/// When the ride started, epoch millis, and the battery it started on.
///
/// THE HISTORY ROW'S SEED. These used to be widget fields, so swiping the app
/// out of recents (which does NOT stop the ride: the service restarts itself a
/// second later) completed a journey that then never appeared in History. The
/// ride survived and its record did not. They live beside the ride now, for the
/// same reason the destination does.
const rideStartedAtKey = 'ride_started_at';
const rideStartBatteryKey = 'ride_start_battery';

/// Whether a ride is in flight, written by the SERVICE and by nobody else.
///
/// THE KILL DISCRIMINATOR. `isRunningService` answers about right now, and a
/// process iOS jetsammed answers the same "no" as a journey the rider finished
/// on purpose. This flag separates them: it goes true as the service starts and
/// false in [GeofenceTaskHandler.onDestroy], which runs on End, on the OS
/// reclaiming the service and on a timeout, and did NOT run on the 16 Aug kill.
/// True with no service running therefore means the ride was interrupted.
///
/// Written HERE rather than in the UI's startRide for the same reason the
/// farewell is spoken here: only this isolate knows the ride really began, and
/// only this isolate is present for both ends of it. See
/// lib/services/ride_resume.dart for what the flag is allowed to buy.
const rideInFlightKey = 'ride_in_flight';

/// Wind-down action ids, shared by the notification buttons and the debug
/// screen's sendDataToTask messages.
const windDownEndNowId = 'wind_down_end_now';
const windDownExtendId = 'wind_down_extend';

/// Wake acknowledgment messages. The two carry the SOURCE because the ride log
/// is the only capture a sideloaded iPhone gives us, and a stand-down looks
/// identical from an earphone tap and from the on-screen button. The 21 Jul
/// bench could not tell them apart, which is what this exists to end: the
/// earphone form carries the remote command that fired, so a real tap leaves
/// proof in the file even with the phone in a pocket.
const wakeAckButtonId = 'wake_ack';
const wakeAckMediaPrefix = 'wake_ack_media:';

/// Bench only: fire a Pocket Pulse chime N ms into a spoken line, reproducing
/// the 21 Jul collision that once stood the wake ladder down. See
/// docs/design/pocket-pulse.md section 7, item 2.
const pulseCollidePrefix = 'test_pulse_collide:';

/// Pocket Pulse's settings, handed to the service at ride start the same way
/// the Sarvam flags are. They live in the STORE rather than in a message
/// because settings are written in the UI isolate's drift database, which the
/// service isolate never opens, and because a restarted service has to be able
/// to read them back.
const pulseIntervalKey = 'pulse_interval_s';
const pulseVibrateKey = 'pulse_vibrate';

/// What Travel Mode speaks in, as the `AppLanguage` tag (`hi-IN`), crossing
/// the isolate the same way and for the same reasons.
///
/// Absent means English, which is the language every string in the app is
/// written in and the only one the bundled greeting clip exists for. A
/// restarted service reads it back, so a ride that was announcing in Marathi
/// before the swipe carries on in Marathi after it.
const languageKey = 'announcement_language';

/// `AppSettings.announceEveryStation`, read once at Start like the language.
///
/// WIRED 12 AUG 2026, AND IT NEVER HAD BEEN. The switch was written to settings
/// and read back into AppSettings and consumed by nothing: the raw key appeared
/// in exactly one file. Its row promised "Off announces only your stop, and
/// still wakes you" while every station was announced anyway, which is worse
/// than the wake toggle deleted on 11 Aug, because that one changed nothing
/// SILENTLY and this one said a sentence.
const announceEveryStationServiceKey = 'announce_every_station_ride';

/// How loud the wake alarm will be, 0.0 to 1.0, measured by the UI at Start.
///
/// CROSSES THROUGH THE STORE BECAUSE IT HAS TO. The number comes from a native
/// method channel registered on the MAIN Flutter engine, and this isolate runs
/// its own engine, so the service cannot ask for it: the call would return null
/// on every real ride while passing every desk test.
///
/// It is a LOG LINE, not a decision. Nothing in the ride reads it. It exists
/// because on 11 Aug 2026 a wake ladder went live, seized the audio session
/// exclusively, climbed all three rungs, and the owner heard nothing, and no
/// log anywhere recorded the one number that decides whether success is
/// audible. Absent means the platform would not say.
///
/// CORRECTED 14 Aug 2026, LATE. An earlier version of this comment said this
/// number was the untrustworthy one. That was backwards, and it was written
/// before the evening's benches finished.
///
/// THIS READING HAS BEEN RIGHT EVERY TIME. `alarmVolume()` activates the
/// session as `.ambient` with `mixWithOthers` before reading, and it reported
/// 90 percent when the rider's slider was at 90. The LADDER's reading is the
/// wrong one: `seizeSession()` takes `.playback` with no options, which is
/// EXCLUSIVE, and then reads 65 percent for the same slider, four samples
/// running.
///
/// So the variable is the CATEGORY, not the timing, and taking an exclusive
/// session appears to change which route's volume iOS reports. That is a
/// HYPOTHESIS awaiting one bench, not a fact. Until it is measured, prefer
/// this number over the ladder's.
const alarmVolumeKey = 'alarm_volume_at_start';

/// The rider's analytics opt-out, `AppSettings.shareAnonymousUsage`.
///
/// Crosses the isolate boundary through the STORE for the same reason the
/// pulse interval does: settings live in drift and the service isolate never
/// opens that database. Written at every Start, so a rider who switches it off
/// between rides is honoured on the next one, and read by a RESTARTED service
/// too, which is what keeps a swiped-away ride from quietly re-enabling it.
///
/// Absent means OFF. A missing key must never read as consent.
const shareUsageKey = 'share_anonymous_usage';

/// The rider changed the Pocket Pulse interval MID-RIDE. Carries seconds, or
/// the literal `off`.
const pulseSetPrefix = 'pulse_set:';

/// The rider's wake toggle, per ride. `wake_enabled:true` or `:false`.
///
/// A COMMAND AND NOT A STORE KEY, deliberately, unlike the pulse settings. Those
/// are settings that must survive a service restart mid-ride; this one must NOT.
/// It resets to armed at every Start by design, and a stored value is exactly
/// how "off" would outlive the journey the rider switched it off for.
const wakeEnabledPrefix = 'wake_enabled:';

/// A pulse interval change from the UI.
///
/// A COMMAND with a null interval means "the rider turned it off". A null
/// COMMAND means "that message was not about the pulse". Collapsing the two
/// would let a garbled message silence the pulse for the rest of a ride, which
/// is why [parsePulseCommand] refuses to guess.
class PulseCommand {
  const PulseCommand(this.intervalS);

  /// Seconds between chimes, or null for off.
  final int? intervalS;
}

/// Reads a [pulseSetPrefix] message, or null if [data] is not one.
///
/// Pure, and separated from the handler's switch for the same reason
/// [parseServiceData] is separated from the client: this is a string crossing
/// an isolate boundary with a plugin either side, so a mistake here is
/// invisible to every other test and surfaces only on a device, mid-ride.
PulseCommand? parsePulseCommand(Object data) {
  if (data is! String || !data.startsWith(pulseSetPrefix)) return null;
  final payload = data.substring(pulseSetPrefix.length);
  if (payload == 'off') return const PulseCommand(null);
  final seconds = int.tryParse(payload);
  // Unparseable: ignore it. Reading a garbled payload as "off" would silence
  // the pulse for the rest of the ride on a single corrupt message.
  return seconds == null ? null : PulseCommand(seconds);
}

/// Whether an alert is asking to be answered right now. Saved as well as sent,
/// for the reason the 30 Jul swipe bench made concrete: these were transient,
/// so a UI the OS recreated (or that the rider swiped away and reopened) came
/// back believing nothing was live. With the alarm sounding, that left NO way
/// to acknowledge it, because liveness is edge-triggered and the next rung
/// does not re-announce it. The store is what a rebuilt UI reads.
const wakeLadderLiveKey = 'wake_ladder_live';
const windDownLiveKey = 'wind_down_live';

/// The live ladder's rung and whether it is still climbing. The alert screen's
/// glow steps with the sound, so a UI born mid-alarm has to know how loud the
/// alarm already is rather than restart its visual at rung one.
const wakeRungKey = 'wake_rung';
const wakeClimbingKey = 'wake_climbing';

/// The live countdown's deadline (epoch millis, 0 for none) and the window it
/// was set from (seconds). Screen 5 needs both to draw a ring that means
/// anything; without them a UI born mid-countdown would invent a fresh minute.
const windDownEndsAtKey = 'wind_down_ends_at_ms';
const windDownWindowKey = 'wind_down_window_s';

/// The station the rider will actually get off at, which after an overshoot is
/// not the one they picked. Empty means "the destination", because saveData has
/// no null. Screen 5 names this station, so a rider carried past Shahad and
/// told to alight at Ambivli is not congratulated on arriving at Shahad.
const alightStationKey = 'alight_station_id';

/// Native call state from iOS CallKit, forwarded main isolate -> service.
/// Android has no counterpart and does not need one: there the audio session
/// already reports a real call, because the ringtone interrupts us.
const wakeCallStatePrefix = 'wake_call_state:';

/// What the iOS audio session did when the alarm asked for it, forwarded main
/// isolate -> service so it lands in the ride log rather than in NSLog, where
/// a sideloaded build cannot read it.
const wakeAudioNotePrefix = 'wake_audio:';

/// Runs the ride inside the Android foreground service isolate so it survives
/// screen lock and app backgrounding.
class GeofenceTaskHandler extends TaskHandler {
  GeofenceChainService? _chain;

  /// Which alerts are asking to be answered. Held here, not read back from the
  /// store, because the notification's buttons are composed from BOTH and one
  /// callback must not wipe the other's buttons off the notification.
  bool _wakeLadderLive = false;
  bool _windDownLive = false;

  /// The ongoing Travel Mode notification's actions, recomputed whenever either
  /// alert changes.
  ///
  /// This is the ack a pocketed, locked phone can actually reach. Until the
  /// 30 Jul bench the wake ladder attached nothing here, so an alarm on a
  /// phone whose app had been swiped out of recents could not be answered at
  /// all: the media session dies with the UI, and the on-screen button dies
  /// with it. The rider's only remaining option was ending the whole journey.
  ///
  /// Android shows at most three actions, which is exactly the worst case here.
  void _updateNotificationButtons() {
    FlutterForegroundTask.updateService(
      notificationButtons: [
        if (_wakeLadderLive)
          const NotificationButton(id: wakeAckButtonId, text: "I'm awake"),
        if (_windDownLive) ...const [
          NotificationButton(id: windDownEndNowId, text: 'End now'),
          NotificationButton(id: windDownExtendId, text: 'Extend 10 min'),
        ],
      ],
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // This isolate has no screen, so a crash in it is SILENT: the ride simply
    // stops watching and the rider finds out by missing their stop. It is
    // therefore the half of the app most worth reporting, and the half a
    // report is least likely to arrive from by any other route.
    //
    // BOUNDED, not open ended. Starting an SDK here happens on the ride's
    // critical path, and this app starts rides in cuttings and tunnels. Two
    // seconds buys the coverage of an error thrown while planning the journey;
    // beyond that the ride matters more than the report of it. Does nothing
    // without a DSN.
    await CrashReporting.initServiceIsolate()
        .timeout(const Duration(seconds: 2))
        .catchError((Object _) {});

    final originId = await FlutterForegroundTask.getData<String>(
      key: originIdKey,
    );
    final destinationId = await FlutterForegroundTask.getData<String>(
      key: destinationIdKey,
    );
    if (originId == null || destinationId == null) {
      return;
    }
    // Set AFTER the ids are proved present, so a service started with an empty
    // store cannot leave a flag behind that outlives it and offers to resume a
    // ride that never had a route. See [rideInFlightKey].
    await FlutterForegroundTask.saveData(key: rideInFlightKey, value: true);
    final sarvamGreeting =
        await FlutterForegroundTask.getData<bool>(key: sarvamGreetingKey) ??
        false;
    final sarvamClips =
        await FlutterForegroundTask.getData<bool>(key: sarvamClipsKey) ?? false;

    // Absent reads as OFF, deliberately: a missing key is not consent.
    final shareUsage =
        await FlutterForegroundTask.getData<bool>(key: shareUsageKey) ?? false;
    // NOT AWAITED AT ALL. Aptabase's init POSTS to the network before it
    // completes and the package sets no timeout, so awaiting it here put a
    // hung socket between the rider and Travel Mode starting. Counting a ride
    // must never delay one. Events queued meanwhile still go out: Analytics
    // waits for readiness on the send side, where nothing is blocked.
    unawaited(
      Analytics.init(enabled: shareUsage, isolate: AnalyticsIsolate.service),
    );

    _chain = GeofenceChainService(
      onLog: _sendLog,
      sarvamGreeting: sarvamGreeting,
      sarvamClips: sarvamClips,
      // The ride events fire from HERE rather than from the UI, because the
      // 30 Jul swipe bench proved the UI can die mid-ride while the service
      // rides on. Reporting from the UI would silently drop exactly the rides
      // that matter most: a pocketed phone with the app swiped away.
      analytics: Analytics(enabled: shareUsage),
      onDestinationReached: () {
        // Sent AND saved, like progress. The save alone was enough while the
        // only reader was the history row at teardown; Screen 5 has to open the
        // moment the rider is standing on the platform, and nothing was
        // announcing that.
        FlutterForegroundTask.sendDataToMain({'destinationReached': true});
        FlutterForegroundTask.saveData(key: destinationReachedKey, value: true);
      },
      onProgress: (reachedIndex, atStation) {
        // Sent AND saved: the stream is the low-latency path, the store is what
        // a recreated process reads. Screen 4 must be right when the OS kills
        // the UI mid-ride and rebuilds it, with no user action.
        FlutterForegroundTask.sendDataToMain({
          'reachedIndex': reachedIndex,
          'atStation': atStation,
        });
        FlutterForegroundTask.saveData(
          key: reachedIndexKey,
          value: reachedIndex,
        );
        FlutterForegroundTask.saveData(key: atStationKey, value: atStation);
      },
      onWakeLadderLive: (live, rung, climbing) {
        _wakeLadderLive = live;
        FlutterForegroundTask.sendDataToMain({
          'wakeLadderLive': live,
          'wakeRung': rung,
          'wakeClimbing': climbing,
        });
        FlutterForegroundTask.saveData(key: wakeLadderLiveKey, value: live);
        // Saved as well as sent, for the same reason liveness is: a UI born
        // mid-alarm (the 30 Jul swipe case) has to show the right glow, not
        // restart the ladder's visual at rung one.
        FlutterForegroundTask.saveData(key: wakeRungKey, value: rung);
        FlutterForegroundTask.saveData(key: wakeClimbingKey, value: climbing);
        _updateNotificationButtons();
      },
      onIosVibrate: () => FlutterForegroundTask.sendDataToMain({
        'vibrate': true,
      }),
      onIosToneCommand: (command, volume) {
        FlutterForegroundTask.sendDataToMain({
          'toneCommand': command,
          'toneVolume': volume,
        });
      },
      onRawFix: (location) {
        FlutterForegroundTask.sendDataToMain({
          'fixLat': location.latitude,
          'fixLng': location.longitude,
          'fixAccuracyM': location.accuracy,
          // Sent raw, sentinel and all. Both platforms use a negative number to
          // mean "no reading", and parseServiceData turns that into null once,
          // at the boundary, so nothing downstream carries the knowledge. It
          // was already on every fix the service saw and was simply dropped
          // here until 18 Aug 2026.
          'fixSpeedMs': location.speed,
        });
      },
      onWindDownLive: (live, endsAt, window) {
        _windDownLive = live;
        // Sent AND saved, for the same reason progress is: the stream is the
        // low-latency path, the store is what a UI born mid-countdown reads.
        // Screen 5 draws real seconds, so a stale deadline is a lie about how
        // long the rider has to get off.
        FlutterForegroundTask.sendDataToMain({
          'windDownLive': live,
          'windDownEndsAtMs': endsAt?.millisecondsSinceEpoch,
          'windDownWindowS': window.inSeconds,
        });
        FlutterForegroundTask.saveData(key: windDownLiveKey, value: live);
        FlutterForegroundTask.saveData(
          key: windDownEndsAtKey,
          value: endsAt?.millisecondsSinceEpoch ?? 0,
        );
        FlutterForegroundTask.saveData(
          key: windDownWindowKey,
          value: window.inSeconds,
        );
        _updateNotificationButtons();
      },
      // Sent AND saved, like everything else the ride learns mid-flight. This
      // one moves at most once per ride, at an overshoot pin, and Screen 5 may
      // well be opened by a process that was recreated in between.
      onAlightingAt: (stationId) {
        FlutterForegroundTask.sendDataToMain({'alightStationId': stationId});
        FlutterForegroundTask.saveData(key: alightStationKey, value: stationId);
      },
      onAutoOff: () => _autoOff(),
    );
    // The ride's own start time, from the store, so the four-hour backstop
    // survives an OS recreation. Reading the clock inside the chain would give
    // a forgotten ride a fresh four hours every time the service restarted,
    // and a restart is not hypothetical: the 30 Jul swipe bench proved the
    // service comes back about a second after the app is swiped away.
    final startedAtMs = await FlutterForegroundTask.getData<int>(
      key: rideStartedAtKey,
    );

    await _chain!.start(
      originId: originId,
      destinationId: destinationId,
      rideStartedAt: startedAtMs == null || startedAtMs <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAtMs),
      pulseIntervalS:
          await FlutterForegroundTask.getData<int>(key: pulseIntervalKey) ?? 0,
      pulseVibrate:
          await FlutterForegroundTask.getData<bool>(key: pulseVibrateKey) ??
          true,
      // fromTag falls back to English for a missing key and for a tag this
      // build does not know, so a store written by an older or newer version
      // can only ever cost the rider their language choice, never the ride.
      language: AppLanguage.fromTag(
        await FlutterForegroundTask.getData<String>(key: languageKey),
      ),
      // Defaults TRUE for a missing key, which is the safe side: an older store,
      // or a service the OS recreated mid-ride, costs the rider extra
      // announcements and never their stop.
      announceEveryStation:
          await FlutterForegroundTask.getData<bool>(
            key: announceEveryStationServiceKey,
          ) ??
          true,
      alarmVolume: await FlutterForegroundTask.getData<double>(
        key: alarmVolumeKey,
      ),
    );
  }

  /// The wind-down countdown expired or [End now] was pressed: run the
  /// normal ride teardown (farewell included), tell a live UI to flip back
  /// to idle, then stop the whole foreground service. The chain is nulled
  /// first so onDestroy cannot run stop() a second time and speak a second
  /// farewell.
  Future<void> _autoOff() async {
    final chain = _chain;
    if (chain == null) return;
    _chain = null;
    FlutterForegroundTask.sendDataToMain({'rideEnded': true});
    // AN ENDING THE APP CHOSE, so the ride is finished and must not be offered
    // back. Written BEFORE the farewell, unlike the line this replaced, because
    // anything sitting behind a 2.5 s spoken farewell is a line that may never
    // run. This path covers the wind-down auto-off and the four-hour timeout,
    // which ends down the same route. See [rideInFlightKey].
    await FlutterForegroundTask.saveData(key: rideInFlightKey, value: false);
    await chain.stop(reason: 'wind-down auto-off');
    await FlutterForegroundTask.stopService();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _chain?.onTick(timestamp);
  }

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case final String message when message.startsWith(wakeEnabledPrefix):
        _chain?.setWakeEnabled(
          message.substring(wakeEnabledPrefix.length) == 'true',
        );
      case wakeAckButtonId:
        // Named apart from the screen button so the ride log says which
        // surface answered, the way the earphone tap already does.
        _chain?.wakeAck(source: 'notification button');
      case windDownEndNowId:
        _chain?.windDownEndNow();
      case windDownExtendId:
        _chain?.windDownExtend();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // onDestroy covers the rider holding End, the OS reclaiming the
    // service, and a timeout. Only the first is the rider's doing, but
    // the handler cannot tell them apart, so the line stays honest about
    // that rather than guessing.
    await _chain?.stop(reason: 'service destroyed (End pressed, or the OS)');
    _chain = null;
    // [rideInFlightKey] IS DELIBERATELY NOT CLEARED HERE, and the 17 Aug 2026
    // bench is why. It used to be, on the reasoning that onDestroy means "an
    // ending we were present for". The logs killed that reasoning twice over.
    //
    // iOS DOES call this on a swipe-away, through applicationWillTerminate,
    // and a swipe is not the rider ending a ride: on iOS it kills Travel Mode
    // silently, with no notification, which is exactly the case worth offering
    // back. And it DID NOT FINISH: both killed rides logged "Journey ending"
    // and then stopped dead, because the process died inside the 2.5 s
    // farewell that this line used to sit behind. The offer appeared because
    // the write was unreachable, which is luck, not a design. A shorter
    // farewell would have silently turned the feature off.
    //
    // The flag is cleared where an ending is actually CHOSEN instead: in
    // [_autoOff] for the wind-down and the four-hour timeout, and in
    // RideServiceClient.stopRide for the rider pressing End journey.
    // The clip flags are per-Start choices, but saveData persists across
    // app restarts. Cleared here so a service start that bypasses the UI
    // (OS recreation, reboot restart) cannot replay a stale opt-in.
    await FlutterForegroundTask.saveData(key: sarvamGreetingKey, value: false);
    await FlutterForegroundTask.saveData(key: sarvamClipsKey, value: false);
    // Same reasoning, and it matters more: a stale true here would have the
    // next ride's UI open claiming an alarm that is not sounding, and claim
    // the rider's media buttons for it.
    _wakeLadderLive = false;
    _windDownLive = false;
    await FlutterForegroundTask.saveData(key: wakeLadderLiveKey, value: false);
    await FlutterForegroundTask.saveData(key: windDownLiveKey, value: false);
    // And the same again: a stale pin from a ride that overshot would name the
    // wrong platform on the NEXT ride's arrival screen.
    await FlutterForegroundTask.saveData(key: alightStationKey, value: '');
  }

  @override
  void onReceiveData(Object data) {
    switch (data) {
      case 'test_tts':
        _chain?.testAnnounce();
      case 'test_wake_alert':
        _chain?.testWakeAlert();
      case 'test_wind_down':
        _chain?.testWindDown();
      case 'test_pulse':
        _chain?.testPulse();
      case final String message when parsePulseCommand(message) != null:
        _chain?.setPulseInterval(parsePulseCommand(message)!.intervalS);
      case final String message when message.startsWith(pulseCollidePrefix):
        _chain?.testPulse(
          collideAfterMs:
              int.tryParse(message.substring(pulseCollidePrefix.length)) ?? 150,
        );
      case wakeAckButtonId:
        _chain?.wakeAck(source: 'screen button');
      case final String message when message.startsWith(wakeAckMediaPrefix):
        final via = message.substring(wakeAckMediaPrefix.length);
        _chain?.wakeAck(
          source: via.isEmpty ? 'media button' : 'media button ($via)',
        );
      case final String message when message.startsWith(wakeCallStatePrefix):
        _chain?.onNativeCallState(
          message.substring(wakeCallStatePrefix.length) == 'true',
        );
      case final String message when message.startsWith(wakeAudioNotePrefix):
        _chain?.onNativeAudioNote(
          message.substring(wakeAudioNotePrefix.length),
        );
      case windDownEndNowId:
        _chain?.windDownEndNow();
      case windDownExtendId:
        _chain?.windDownExtend();
    }
  }

  void _sendLog(String message) {
    FlutterForegroundTask.sendDataToMain({
      'timestampMillis': DateTime.now().millisecondsSinceEpoch,
      'message': message,
    });
  }
}
