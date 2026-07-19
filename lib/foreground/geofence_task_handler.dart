import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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

/// Whether the CURRENT ride announced arrival at its destination. Written false
/// by the UI at Start, true by the service on arrival, read back by the UI at
/// Stop to decide if the turnaround origin default can be trusted.
const destinationReachedKey = 'destination_reached';

/// Wind-down action ids, shared by the notification buttons and the debug
/// screen's sendDataToTask messages.
const windDownEndNowId = 'wind_down_end_now';
const windDownExtendId = 'wind_down_extend';

/// Runs the ride inside the Android foreground service isolate so it survives
/// screen lock and app backgrounding.
class GeofenceTaskHandler extends TaskHandler {
  GeofenceChainService? _chain;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final originId = await FlutterForegroundTask.getData<String>(key: originIdKey);
    final destinationId =
        await FlutterForegroundTask.getData<String>(key: destinationIdKey);
    if (originId == null || destinationId == null) {
      return;
    }
    final sarvamGreeting =
        await FlutterForegroundTask.getData<bool>(key: sarvamGreetingKey) ??
            false;

    _chain = GeofenceChainService(
      onLog: _sendLog,
      sarvamGreeting: sarvamGreeting,
      onDestinationReached: () {
        FlutterForegroundTask.saveData(key: destinationReachedKey, value: true);
      },
      onWakeLadderLive: (live) {
        FlutterForegroundTask.sendDataToMain({'wakeLadderLive': live});
      },
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
        });
      },
      onWindDownLive: (live) {
        FlutterForegroundTask.sendDataToMain({'windDownLive': live});
        // The buttons appear on the ongoing Travel Mode notification only
        // while the countdown runs, so a pocketed phone can answer without
        // being unlocked. Android only in practice; the iOS notification is
        // disabled and its real surface is the Phase 2 Arrival screen.
        FlutterForegroundTask.updateService(
          notificationButtons: live
              ? const [
                  NotificationButton(id: windDownEndNowId, text: 'End now'),
                  NotificationButton(
                    id: windDownExtendId,
                    text: 'Extend 10 min',
                  ),
                ]
              : const [],
        );
      },
      onAutoOff: () => _autoOff(),
    );
    await _chain!.start(originId: originId, destinationId: destinationId);
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
    await chain.stop();
    await FlutterForegroundTask.stopService();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _chain?.onTick(timestamp);
  }

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case windDownEndNowId:
        _chain?.windDownEndNow();
      case windDownExtendId:
        _chain?.windDownExtend();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _chain?.stop();
    _chain = null;
    // The greeting flag is a per-Start choice, but saveData persists across
    // app restarts. Cleared here so a service start that bypasses the UI
    // (OS recreation, reboot restart) cannot replay a stale opt-in.
    await FlutterForegroundTask.saveData(key: sarvamGreetingKey, value: false);
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
      case 'wake_ack':
        _chain?.wakeAck();
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
