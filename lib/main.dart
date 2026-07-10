import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'foreground/geofence_task_handler.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const CommuteGuardianDebugApp());
}

class CommuteGuardianDebugApp extends StatelessWidget {
  const CommuteGuardianDebugApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Commute Guardian (Phase 0 debug)',
      theme: ThemeData.dark(useMaterial3: true),
      home: const GeofenceDebugScreen(),
    );
  }
}

/// Phase 0 proof-of-concept screen: start/stop the hardcoded Dombivli -> Shahad
/// geofence chain and watch ENTER events stream in. Not product UI.
class GeofenceDebugScreen extends StatefulWidget {
  const GeofenceDebugScreen({super.key});

  @override
  State<GeofenceDebugScreen> createState() => _GeofenceDebugScreenState();
}

class _GeofenceDebugScreenState extends State<GeofenceDebugScreen> {
  final List<String> _logs = [];
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _initService();
    _syncRunningState();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }

  Future<void> _syncRunningState() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) {
      setState(() => _isRunning = running);
    }
  }

  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'geofence_chain',
        channelName: 'Travel Mode',
        channelDescription: 'Announces stations while Travel Mode is active.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
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

  void _onReceiveTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      final message = data['message'] as String?;
      if (message != null) {
        setState(() {
          _logs.insert(0, message);
        });
      }
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();

    final whileInUse = await Permission.locationWhenInUse.request();
    if (whileInUse.isGranted) {
      await Permission.locationAlways.request();
    }

    if (Platform.isAndroid &&
        !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  Future<void> _start() async {
    await _requestPermissions();

    final result = await FlutterForegroundTask.startService(
      serviceId: 1,
      notificationTitle: 'Travel Mode active',
      notificationText: 'Shahad -> Dombivli geofence chain running',
      callback: geofenceTaskStartCallback,
    );

    if (result is ServiceRequestSuccess) {
      setState(() => _isRunning = true);
    }
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    setState(() => _isRunning = false);
  }

  void _testTts() {
    FlutterForegroundTask.sendDataToTask('test_tts');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Geofence chain: Shahad -> Dombivli')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isRunning ? null : _start,
                    child: const Text('Start Travel Mode'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isRunning ? _stop : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _isRunning ? _testTts : null,
                child: const Text('Test TTS announcement'),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _logs.length,
              itemBuilder: (context, index) => Text(
                _logs[index],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
