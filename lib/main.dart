import 'dart:io';

import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/station_repository.dart';
import 'foreground/geofence_task_handler.dart';
import 'models/journey.dart';
import 'models/station.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const CommuteGuardianDebugApp());
}

class CommuteGuardianDebugApp extends StatelessWidget {
  const CommuteGuardianDebugApp({super.key, this.loadRepository});

  final Future<StationRepository> Function()? loadRepository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Commute Guardian (Phase 0 debug)',
      theme: ThemeData.dark(useMaterial3: true),
      home: RideDebugScreen(loadRepository: loadRepository),
    );
  }
}

/// Debug screen: pick a ride, start it, and watch events stream in. Not product
/// UI (that is Phase 2, per the Figma designs), but the route is real: any two
/// stations on the network, planned by JourneyPlanner.
class RideDebugScreen extends StatefulWidget {
  const RideDebugScreen({super.key, this.loadRepository});

  /// How to get the station network. Overridable so a test can hand in a
  /// repository read straight off disk: `rootBundle` does real I/O, which cannot
  /// complete inside the fake-async zone widget tests pump in.
  final Future<StationRepository> Function()? loadRepository;

  @override
  State<RideDebugScreen> createState() => _RideDebugScreenState();
}

class _RideDebugScreenState extends State<RideDebugScreen> {
  final List<String> _logs = [];
  bool _isRunning = false;

  StationRepository? _repo;
  List<Station> _stations = const [];
  String? _originId;
  String? _destinationId;

  // Owned here rather than left to DropdownMenu's own internal controller, so
  // that filling the origin in from GPS can update the field's text without
  // rebuilding the menu. Rebuilding it would snap a menu the rider had already
  // opened shut under their thumb.
  final TextEditingController _originField = TextEditingController();
  final TextEditingController _destinationField = TextEditingController();

  /// The planned ride, or the reason it cannot be planned. Recomputed on every
  /// pick, so Start is only ever offered for a route that actually works.
  Journey? _journey;
  String? _planError;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _initService();
    _syncRunningState();
    _loadNetwork();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _originField.dispose();
    _destinationField.dispose();
    super.dispose();
  }

  Future<void> _loadNetwork() async {
    final repo = await (widget.loadRepository ?? StationRepository.load)();
    final stations = repo.stationsById.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (!mounted) return;
    setState(() {
      _repo = repo;
      _stations = stations;
    });
    await _defaultOriginToNearestStation();
  }

  /// Worst fix we will name a station from. A fix vaguer than this says nothing
  /// useful about which platform the rider is on.
  static const _maxOriginAccuracyM = 500.0;

  /// How far from a station the rider can be and still be plausibly setting off
  /// from it. Generous on purpose (people open the app on the walk in), but it
  /// rules out a fix that is not near the network at all.
  static const _maxOriginDistanceM = 3000.0;

  /// A ride starts where the rider is standing, so default the origin to the
  /// nearest station rather than making them find it in a list of 127.
  ///
  /// Only from a fix worth trusting. Indoors, or on a phone with no SIM, Android
  /// will happily hand back a fix tens of kilometres out, and the nearest station
  /// to a garbage fix is a garbage origin, which would silently plan a ride the
  /// rider is not on. Better to leave the field empty and make them pick.
  Future<void> _defaultOriginToNearestStation() async {
    final repo = _repo;
    if (repo == null) return;

    try {
      if (!await fl.FlLocation.isLocationServicesEnabled) return;
      final location = await fl.FlLocation.getLocation(
        accuracy: fl.LocationAccuracy.balanced,
      );
      // The fix can land long after the screen is up. If the rider has already
      // chosen an origin by then, theirs wins: a late GPS result must never
      // overwrite a deliberate choice.
      if (!mounted || _originId != null) return;
      if (location.accuracy > _maxOriginAccuracyM) return;

      final nearest = repo.nearestStation(location.latitude, location.longitude);
      final distance = repo.distanceToM(
        nearest,
        location.latitude,
        location.longitude,
      );
      if (distance > _maxOriginDistanceM) return;

      setState(() {
        _originId = nearest.id;
        _originField.text = nearest.name;
      });
      _replan();
    } catch (_) {
      // No fix available. The dropdown is the fallback, so this is not an error.
    }
  }

  void _replan() {
    final repo = _repo;
    final originId = _originId;
    final destinationId = _destinationId;
    if (repo == null || originId == null || destinationId == null) {
      setState(() {
        _journey = null;
        _planError = null;
      });
      return;
    }

    try {
      final journey =
          repo.planner.plan(originId: originId, destinationId: destinationId);
      setState(() {
        _journey = journey;
        _planError = null;
      });
    } catch (error) {
      setState(() {
        _journey = null;
        _planError = error is ArgumentError
            ? '${error.message}'
            : 'Cannot plan this ride.';
      });
    }
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
    final journey = _journey;
    if (journey == null) return;

    await _requestPermissions();

    // The service isolate has its own heap and cannot read this screen's state,
    // so hand the ride over through the shared store it can read on start.
    await FlutterForegroundTask.saveData(
      key: originIdKey,
      value: journey.originStationId,
    );
    await FlutterForegroundTask.saveData(
      key: destinationIdKey,
      value: journey.destinationStationId,
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: 1,
      notificationTitle: 'Travel Mode active',
      notificationText: '${_name(journey.originStationId)} to '
          '${_name(journey.destinationStationId)}',
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

  String _name(String stationId) => _repo?.stationsById[stationId]?.name ?? stationId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Commute Guardian (debug)')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StationPicker(
                  label: 'Origin',
                  stations: _stations,
                  controller: _originField,
                  // Changing the ride mid-ride would leave the running service on
                  // the old one, which is a lie the log would not show.
                  enabled: !_isRunning,
                  onChanged: (id) {
                    setState(() => _originId = id);
                    _replan();
                  },
                ),
                const SizedBox(height: 12),
                _StationPicker(
                  label: 'Destination',
                  stations: _stations,
                  controller: _destinationField,
                  enabled: !_isRunning,
                  onChanged: (id) {
                    setState(() => _destinationId = id);
                    _replan();
                  },
                ),
                const SizedBox(height: 12),
                _JourneySummary(journey: _journey, error: _planError),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _isRunning || _journey == null ? null : _start,
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: OutlinedButton(
              onPressed: _isRunning ? _testTts : null,
              child: const Text('Test TTS announcement'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

/// One station dropdown. 127 stations is too many to scroll, so it filters as
/// you type.
class _StationPicker extends StatelessWidget {
  const _StationPicker({
    required this.label,
    required this.stations,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final List<Station> stations;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<String>(
      label: Text(label),
      enabled: enabled && stations.isNotEmpty,
      controller: controller,
      expandedInsets: EdgeInsets.zero,
      enableFilter: true,
      requestFocusOnTap: true,
      menuHeight: 320,
      dropdownMenuEntries: [
        for (final station in stations)
          DropdownMenuEntry(
            value: station.id,
            label: station.name,
            trailingIcon: Text(
              station.code,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
      ],
      onSelected: (id) {
        if (id != null) onChanged(id);
      },
    );
  }
}

/// What the picked ride actually is: the stations it will pass, and any train
/// change it needs. Shown before Start so a wrong pick is obvious on the
/// platform, not thirty minutes into the wrong train.
class _JourneySummary extends StatelessWidget {
  const _JourneySummary({required this.journey, required this.error});

  final Journey? journey;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return Text(
        error!,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      );
    }
    if (journey == null) {
      return Text(
        'Pick an origin and a destination.',
        style: theme.textTheme.bodySmall,
      );
    }

    final ride = journey!;
    // The overshoot pin is a safety net, not part of the trip, so it would only
    // confuse the summary.
    final stops = ride.chain
        .where((s) => s.id != ride.overshootStationId)
        .map((s) => s.name)
        .join(' -> ');
    final nameOf = {for (final s in ride.chain) s.id: s.name};
    final changes = ride.interchanges.isEmpty
        ? 'No change of train.'
        : ride.interchanges
            .map((i) => 'Change at ${nameOf[i.stationId] ?? i.stationId} onto '
                '${i.toLineShortName}'
                '${i.platform == null ? '' : ' (platform ${i.platform})'}.')
            .join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(stops, style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          '${ride.chain.length - 1} stations. $changes',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}
