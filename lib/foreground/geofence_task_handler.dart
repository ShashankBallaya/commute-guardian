import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../services/geofence_chain_service.dart';

/// Entry point the foreground service isolate calls to install the handler.
/// Must stay top-level (or static) per flutter_foreground_task's contract.
@pragma('vm:entry-point')
void geofenceTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(GeofenceTaskHandler());
}

/// Runs the Kalyan -> Digha geofence chain inside the Android foreground
/// service isolate so it survives screen lock / app backgrounding.
class GeofenceTaskHandler extends TaskHandler {
  GeofenceChainService? _chain;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _chain = GeofenceChainService(onLog: _sendLog);
    await _chain!.start();
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
    if (data == 'test_tts') {
      _chain?.testAnnounce();
    }
  }

  void _sendLog(String message) {
    FlutterForegroundTask.sendDataToMain({
      'timestampMillis': DateTime.now().millisecondsSinceEpoch,
      'message': message,
    });
  }
}
