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

/// The locked design system (Figma reviews, 05-09 Jul 2026): dark navy ground,
/// burgundy card surfaces, cream text. Crimson fill is reserved for the one
/// action that starts or ends a journey; nothing else may use it. The green
/// dot means live/tracking, amber means acquiring.
abstract final class Palette {
  static const navy = Color(0xFF1B2537);
  static const burgundy = Color(0xFF3A2528);
  static const cream = Color(0xFFF2E7D5);
  static const crimson = Color(0xFFA8202B);
  static const dotGreen = Color(0xFF3DBC77);
  static const dotAmber = Color(0xFFD9A03D);

  static Color creamDim(double opacity) => cream.withValues(alpha: opacity);
}

class CommuteGuardianDebugApp extends StatelessWidget {
  const CommuteGuardianDebugApp({super.key, this.loadRepository});

  final Future<StationRepository> Function()? loadRepository;

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return MaterialApp(
      title: 'Commute Guardian (Phase 0 debug)',
      theme: base.copyWith(
        scaffoldBackgroundColor: Palette.navy,
        colorScheme: base.colorScheme.copyWith(
          surface: Palette.navy,
          primary: Palette.cream,
          onSurface: Palette.cream,
        ),
        textTheme: base.textTheme.apply(
          bodyColor: Palette.cream,
          displayColor: Palette.cream,
        ),
        // The pickers: dark wells inside the burgundy card, no hard borders.
        dropdownMenuTheme: DropdownMenuThemeData(
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.black.withValues(alpha: 0.25),
            labelStyle: TextStyle(color: Palette.creamDim(0.6)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
          menuStyle: const MenuStyle(
            backgroundColor: WidgetStatePropertyAll(Palette.burgundy),
          ),
          textStyle: const TextStyle(color: Palette.cream),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: Palette.burgundy,
          contentTextStyle: const TextStyle(color: Palette.cream),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: RideDebugScreen(loadRepository: loadRepository),
    );
  }
}

/// Debug screen: pick a ride, start it, and watch events stream in. Wears the
/// approved Phase 2 design system (quiet status chip, burgundy cards, crimson
/// journey CTA, actions in the thumb zone), but it is still the debug tool:
/// the raw event log stays, which no product screen will have.
class RideDebugScreen extends StatefulWidget {
  const RideDebugScreen({super.key, this.loadRepository});

  /// How to get the station network. Overridable so a test can hand in a
  /// repository read straight off disk: `rootBundle` does real I/O, which cannot
  /// complete inside the fake-async zone widget tests pump in.
  final Future<StationRepository> Function()? loadRepository;

  @override
  State<RideDebugScreen> createState() => _RideDebugScreenState();
}

/// What the status chip currently knows about where the rider is.
enum _GpsState { locating, located, unavailable }

class _RideDebugScreenState extends State<RideDebugScreen> {
  final List<String> _logs = [];
  bool _isRunning = false;

  StationRepository? _repo;
  List<Station> _stations = const [];
  String? _originId;
  String? _destinationId;

  /// Feeds the "You're near: X" chip. Distinct from the origin pick: the chip
  /// always reports the latest fix, while the origin field is a one-shot
  /// default the rider may override.
  _GpsState _gpsState = _GpsState.locating;
  String? _nearStationName;

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
  /// Only from a fix worth trusting. The nearest station to a vague fix is a
  /// guess, and a wrong guess here silently plans a ride the rider is not on,
  /// which is worse than not guessing: leave the field empty and let them pick.
  /// Precautionary, not a fix for anything seen in the field, and the thresholds
  /// below are judgement calls rather than measurements.
  Future<void> _defaultOriginToNearestStation() async {
    final repo = _repo;
    if (repo == null) return;

    try {
      if (!await fl.FlLocation.isLocationServicesEnabled) {
        _setGps(_GpsState.unavailable);
        return;
      }
      final location = await fl.FlLocation.getLocation(
        accuracy: fl.LocationAccuracy.balanced,
      );
      if (!mounted) return;
      if (location.accuracy > _maxOriginAccuracyM) {
        _setGps(_GpsState.unavailable);
        return;
      }

      final nearest = repo.nearestStation(location.latitude, location.longitude);
      final distance = repo.distanceToM(
        nearest,
        location.latitude,
        location.longitude,
      );
      if (distance > _maxOriginDistanceM) {
        _setGps(_GpsState.unavailable);
        return;
      }

      _setGps(_GpsState.located, nearStation: nearest.name);

      // The fix can land long after the screen is up. If the rider has already
      // chosen an origin by then, theirs wins: a late GPS result must never
      // overwrite a deliberate choice.
      if (_originId != null) return;
      setState(() {
        _originId = nearest.id;
        _originField.text = nearest.name;
      });
      _replan();
    } catch (_) {
      // No fix available. The dropdown is the fallback, so this is not an error.
      _setGps(_GpsState.unavailable);
    }
  }

  void _setGps(_GpsState state, {String? nearStation}) {
    if (!mounted) return;
    setState(() {
      _gpsState = state;
      _nearStationName = nearStation;
    });
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
    await _defaultOriginToRideEnd();
  }

  /// The next ride usually starts where the last one ended (ride out, turn
  /// around, ride back), so after a stop the origin defaults to the finished
  /// ride's destination and the old destination is cleared for a fresh pick.
  /// Before this, the origin kept the morning's value until the app was killed
  /// (both phones, 13 Jul ride test, at the Thane turnaround).
  ///
  /// A rider who bailed out mid-ride is not at the destination, but the field
  /// is editable and a plausible default beats a stale one. The ride is read
  /// from the service's store, not [_journey], so it survives the app being
  /// restarted while the service ran; if even the store has no ride, fall back
  /// to the GPS fill.
  Future<void> _defaultOriginToRideEnd() async {
    final destinationId =
        await FlutterForegroundTask.getData<String>(key: destinationIdKey);
    if (!mounted) return;
    final destination = _repo?.stationsById[destinationId];

    setState(() {
      _originId = destination?.id;
      _originField.text = destination?.name ?? '';
      _destinationId = null;
      _destinationField.clear();
    });
    _replan();

    if (destination == null) {
      await _defaultOriginToNearestStation();
    } else {
      _setGps(_GpsState.located, nearStation: destination.name);
    }
  }

  void _testTts() {
    FlutterForegroundTask.sendDataToTask('test_tts');
  }

  String _name(String stationId) => _repo?.stationsById[stationId]?.name ?? stationId;

  void _holdToEndHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hold to end the journey.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusChip(state: _gpsState, stationName: _nearStationName),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: Palette.burgundy,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.all(16),
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
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _JourneySummary(journey: _journey, error: _planError),
              const SizedBox(height: 12),
              Expanded(child: _DebugLog(logs: _logs)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _isRunning ? _testTts : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Palette.creamDim(0.75),
                  disabledForegroundColor: Palette.creamDim(0.25),
                  side: BorderSide(
                    color: _isRunning
                        ? Palette.creamDim(0.3)
                        : Palette.creamDim(0.12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text('Test announcement'),
              ),
              const SizedBox(height: 12),
              _JourneyCta(
                isRunning: _isRunning,
                canStart: _journey != null,
                onStart: _start,
                onEnd: _stop,
                onEndTap: _holdToEndHint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet status chip: burgundy surface, never loud, the dot alone carries
/// the GPS state (green = fixed, amber = acquiring, dim = unavailable).
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state, required this.stationName});

  final _GpsState state;
  final String? stationName;

  @override
  Widget build(BuildContext context) {
    final (dotColor, label, station) = switch (state) {
      _GpsState.locating => (Palette.dotAmber, 'Locating...', null),
      _GpsState.located => (Palette.dotGreen, "You're near: ", stationName),
      _GpsState.unavailable => (
          Palette.creamDim(0.25),
          'Location unavailable',
          null,
        ),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        decoration: BoxDecoration(
          color: Palette.burgundy,
          borderRadius: BorderRadius.circular(28),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: state == _GpsState.located
                    ? [
                        BoxShadow(
                          color: Palette.dotGreen.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Text.rich(
              TextSpan(
                text: label,
                children: [
                  if (station != null)
                    TextSpan(
                      text: station,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                ],
              ),
              style: TextStyle(fontSize: 15, color: Palette.creamDim(0.9)),
            ),
          ],
        ),
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
            style: MenuItemButton.styleFrom(foregroundColor: Palette.cream),
            trailingIcon: Text(
              station.code,
              style: TextStyle(fontSize: 11, color: Palette.creamDim(0.5)),
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
/// platform, not thirty minutes into the wrong train. Info rows are the
/// quietest element on screen: caption text, bullet separators, no card.
class _JourneySummary extends StatelessWidget {
  const _JourneySummary({required this.journey, required this.error});

  final Journey? journey;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Text(
        error!,
        style: const TextStyle(fontSize: 13, color: Palette.dotAmber),
      );
    }
    if (journey == null) {
      return Text(
        'Pick an origin and a destination.',
        style: TextStyle(fontSize: 13, color: Palette.creamDim(0.5)),
      );
    }

    final ride = journey!;
    // The overshoot pin is a safety net, not part of the trip, so it would only
    // confuse the summary. Counting off the filtered list also keeps the count
    // honest at a terminus, where there is no overshoot pin to exclude.
    final stops =
        ride.chain.where((s) => s.id != ride.overshootStationId).toList();
    final nameOf = {for (final s in ride.chain) s.id: s.name};
    final changes = ride.interchanges.isEmpty
        ? 'No change of train.'
        : ride.interchanges.map((i) {
            final at = nameOf[i.stationId] ?? i.stationId;
            if (i.walkToStationName != null) {
              return 'At $at walk across to ${i.walkToStationName}, then '
                  '${i.toLineShortName} towards ${i.towardsStationName}.';
            }
            if (i.isSameNamedService) {
              return 'Change at $at for the train towards '
                  '${i.towardsStationName}.';
            }
            return 'Change at $at onto ${i.toLineShortName}'
                '${i.platform == null ? '' : ' (platform ${i.platform})'}.';
          }).join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${stops.length} stations • $changes',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Palette.creamDim(0.85),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          stops.map((s) => s.name).join(' → '),
          style: TextStyle(fontSize: 12, color: Palette.creamDim(0.5)),
        ),
      ],
    );
  }
}

/// The raw event stream. Debug-only affordance: kept readable but visually
/// quiet, so the journey CTA stays the loudest element on screen.
class _DebugLog extends StatelessWidget {
  const _DebugLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Palette.creamDim(0.1)),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Debug log',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: Palette.creamDim(0.4),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      'Events will stream here once a journey starts.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Palette.creamDim(0.35),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: logs.length,
                    itemBuilder: (context, index) => Text(
                      logs[index],
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Palette.creamDim(0.55),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The one crimson element on screen (locked rule: crimson fill only ever
/// starts or ends a journey). Idle it reads Start journey; while a ride runs
/// it becomes End journey with hold-to-confirm, so a pocketed thumb cannot
/// kill Travel Mode mid-ride.
class _JourneyCta extends StatelessWidget {
  const _JourneyCta({
    required this.isRunning,
    required this.canStart,
    required this.onStart,
    required this.onEnd,
    required this.onEndTap,
  });

  final bool isRunning;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );

    if (!isRunning) {
      return ElevatedButton(
        onPressed: canStart ? onStart : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Palette.crimson,
          foregroundColor: Palette.cream,
          disabledBackgroundColor: Palette.burgundy,
          disabledForegroundColor: Palette.creamDim(0.35),
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: shape,
          elevation: 0,
        ),
        child: const Text(
          'Start journey',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
      );
    }

    return ElevatedButton(
      onPressed: onEndTap,
      onLongPress: onEnd,
      style: ElevatedButton.styleFrom(
        backgroundColor: Palette.crimson,
        foregroundColor: Palette.cream,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: shape,
        elevation: 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'End journey',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          Text(
            'hold to confirm',
            style: TextStyle(fontSize: 12, color: Palette.creamDim(0.7)),
          ),
        ],
      ),
    );
  }
}
