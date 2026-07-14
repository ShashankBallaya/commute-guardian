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

/// Whether the CURRENT ride announced arrival at its destination. Written false
/// by the UI at Start, true by the service on arrival, read back by the UI at
/// Stop to decide if the turnaround origin default can be trusted.
const destinationReachedKey = 'destination_reached';

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

    _chain = GeofenceChainService(
      onLog: _sendLog,
      onDestinationReached: () {
        FlutterForegroundTask.saveData(key: destinationReachedKey, value: true);
      },
      onWakeLadderLive: (live) {
        FlutterForegroundTask.sendDataToMain({'wakeLadderLive': live});
      },
      onRawFix: (location) {
        FlutterForegroundTask.sendDataToMain({
          'fixLat': location.latitude,
          'fixLng': location.longitude,
          'fixAccuracyM': location.accuracy,
        });
      },
    );
    await _chain!.start(originId: originId, destinationId: destinationId);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Geofence status is event-driven (see GeofenceChainService), nothing
    // to do on the fixed repeat tick.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _chain?.stop();
    _chain = null;
  }

  @override
  void onReceiveData(Object data) {
    switch (data) {
      case 'test_tts':
        _chain?.testAnnounce();
      case 'test_wake_alert':
        _chain?.testWakeAlert();
      case 'wake_ack':
        _chain?.wakeAck();
    }
  }

  void _sendLog(String message) {
    FlutterForegroundTask.sendDataToMain({
      'timestampMillis': DateTime.now().millisecondsSinceEpoch,
      'message': message,
    });
  }
}
