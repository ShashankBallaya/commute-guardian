import 'dart:io';

import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  const CommuteGuardianDebugApp({
    super.key,
    this.loadRepository,
    this.acquireFix,
  });

  final Future<StationRepository> Function()? loadRepository;
  final Future<fl.Location> Function()? acquireFix;

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
        // The pickers and the search sheet's field: dark wells inside the
        // burgundy surfaces, no hard borders.
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.25),
          labelStyle: TextStyle(color: Palette.creamDim(0.6)),
          hintStyle: TextStyle(color: Palette.creamDim(0.4)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
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
      home: RideDebugScreen(
        loadRepository: loadRepository,
        acquireFix: acquireFix,
      ),
    );
  }
}

/// Debug screen: pick a ride, start it, and watch events stream in. Wears the
/// approved Phase 2 design system (quiet status chip, burgundy cards, crimson
/// journey CTA, actions in the thumb zone), but it is still the debug tool:
/// the raw event log stays, which no product screen will have.
class RideDebugScreen extends StatefulWidget {
  const RideDebugScreen({super.key, this.loadRepository, this.acquireFix});

  /// How to get the station network. Overridable so a test can hand in a
  /// repository read straight off disk: `rootBundle` does real I/O, which cannot
  /// complete inside the fake-async zone widget tests pump in.
  final Future<StationRepository> Function()? loadRepository;

  /// How to get a one-shot fix. Overridable because the real plugin's channel
  /// never answers in a widget test (it neither resolves nor throws), which
  /// would pin the chip on "Locating..." forever there.
  final Future<fl.Location> Function()? acquireFix;

  @override
  State<RideDebugScreen> createState() => _RideDebugScreenState();
}

/// What the status chip currently knows about where the rider is.
enum _GpsState { locating, located, unavailable }

/// Carries the wake ladder's earphone-tap acknowledgment. Native side: a
/// MediaSessionCompat in MainActivity (Android) and MPRemoteCommandCenter in
/// the AppDelegate (iOS), activated only while a ladder is live so this app
/// owns media buttons exactly when a tap means "I'm awake" and never longer.
/// Lives in the UI isolate because that is the engine the native side is
/// attached to; the ack is forwarded to the service isolate over the same
/// seam the test buttons use. Best-effort by design: if the OS has killed the
/// backgrounded activity the tap is lost, and the escalation plus the manual
/// dismiss remain the guaranteed fallback.
const _mediaAckChannel = MethodChannel('commute_guardian/media_ack');

class _RideDebugScreenState extends State<RideDebugScreen> {
  final List<String> _logs = [];
  bool _isRunning = false;

  /// Whether the service's wake ladder is currently asking to be
  /// acknowledged. Drives the "I'm awake" button and the media session.
  bool _wakeLadderLive = false;
  bool _windDownLive = false;

  StationRepository? _repo;
  List<Station> _stations = const [];
  String? _originId;
  String? _destinationId;

  /// Feeds the "You're near: X" chip. Distinct from the origin pick: the chip
  /// always reports the latest fix, while the origin field is a one-shot
  /// default the rider may override.
  _GpsState _gpsState = _GpsState.locating;
  String? _nearStationName;

  /// Whether the rider waved the "tap the chip to retry" tip away this
  /// session. The tip is contextual: it appears with the unavailable state,
  /// which is exactly when a new user needs to learn the chip is tappable,
  /// and leaves on its own the moment a fix lands.
  bool _chipTipDismissed = false;

  /// The freshest fix streamed up from the running service. At ride end this
  /// is seconds old and free, so it names the rider's position instantly; a
  /// cold GPS acquisition indoors can hang instead (13 Jul bench).
  ({double lat, double lng, double accuracyM, DateTime at})? _lastServiceFix;

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
    _mediaAckChannel.setMethodCallHandler(_onMediaAck);
    _initService();
    _syncRunningState();
    _loadNetwork();
  }

  /// A media button arrived from the native session while a ladder was live:
  /// the earphone tap. Forward it to the service isolate, where the ladder
  /// runs.
  Future<dynamic> _onMediaAck(MethodCall call) async {
    if (call.method == 'ack') {
      FlutterForegroundTask.sendDataToTask('wake_ack');
      setState(() {
        _logs.insert(0, 'Media button received, ack forwarded to service.');
      });
    }
    return null;
  }

  /// Claims (or releases) media-button routing natively. Held only while a
  /// ladder is live: outside that window the rider's earphone taps must keep
  /// controlling their music, not us.
  Future<void> _setMediaSession(bool active) async {
    try {
      await _mediaAckChannel.invokeMethod(active ? 'startSession' : 'stopSession');
    } catch (error) {
      setState(() {
        _logs.insert(0, 'Media session ${active ? 'start' : 'stop'} failed: $error');
      });
    }
  }

  /// The chip's tap: ask for a fresh fix. A single 8s attempt at launch is a
  /// coin flip indoors on an old phone (14 Jul bench, twice), so the miss must
  /// not be a final verdict. No-op mid-ride: the service stream owns the chip.
  void _retryLocate() {
    if (_isRunning || _gpsState == _GpsState.locating) return;
    _defaultOriginToNearestStation();
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
  Future<void> _defaultOriginToNearestStation() async {
    if (_repo == null) return;
    // Shown while acquiring, so the chip never keeps claiming an old position
    // during a slow fix (it sat on the pre-ride station through the whole
    // post-ride acquisition on the 13 Jul bench).
    _setGps(_GpsState.locating);

    try {
      final location = await (widget.acquireFix ?? _acquireFixLive)();
      if (!mounted) return;
      _applyOriginFix(location.latitude, location.longitude, location.accuracy);
    } catch (_) {
      // No fix in time. The picker is the fallback, so this is not an error.
      _setGps(_GpsState.unavailable);
    }
  }

  Future<fl.Location> _acquireFixLive() async {
    if (!await fl.FlLocation.isLocationServicesEnabled) {
      throw StateError('Location services are off.');
    }
    // Bounded: without a limit an indoor acquisition can wait forever.
    return fl.FlLocation.getLocation(
      accuracy: fl.LocationAccuracy.balanced,
      timeLimit: const Duration(seconds: 8),
    );
  }

  /// Names the nearest station from a fix: updates the chip, and fills the
  /// origin when the rider has not picked one (a fix must never overwrite a
  /// deliberate choice). The one gate for every fix source, live GPS or the
  /// service stream. Returns whether the fix could name a station.
  ///
  /// Only from a fix worth trusting. The nearest station to a vague fix is a
  /// guess, and a wrong guess here silently plans a ride the rider is not on,
  /// which is worse than not guessing: leave the field empty and let them
  /// pick. The thresholds are judgement calls rather than measurements.
  bool _applyOriginFix(double lat, double lng, double accuracyM) {
    final repo = _repo;
    if (repo == null || !mounted) return false;
    if (accuracyM > _maxOriginAccuracyM) {
      _setGps(_GpsState.unavailable);
      return false;
    }

    final nearest = repo.nearestStation(lat, lng);
    if (repo.distanceToM(nearest, lat, lng) > _maxOriginDistanceM) {
      // Position known but nowhere near the network. The chip has no station
      // to name, and admitting that beats keeping a stale one on screen.
      _setGps(_GpsState.unavailable);
      return false;
    }

    _setGps(_GpsState.located, nearStation: nearest.name);
    if (_originId == null) {
      setState(() {
        _originId = nearest.id;
        _originField.text = nearest.name;
      });
      _replan();
    }
    return true;
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
      final journey = repo.planner.plan(
        originId: originId,
        destinationId: destinationId,
      );
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

      final ladderLive = data['wakeLadderLive'] as bool?;
      if (ladderLive != null) {
        setState(() => _wakeLadderLive = ladderLive);
        _setMediaSession(ladderLive);
      }

      final windDownLive = data['windDownLive'] as bool?;
      if (windDownLive != null) {
        setState(() => _windDownLive = windDownLive);
      }

      if (data['rideEnded'] == true) {
        _onRideEndedByService();
      }

      final lat = (data['fixLat'] as num?)?.toDouble();
      final lng = (data['fixLng'] as num?)?.toDouble();
      final accuracyM = (data['fixAccuracyM'] as num?)?.toDouble();
      if (lat != null && lng != null && accuracyM != null) {
        _lastServiceFix = (
          lat: lat,
          lng: lng,
          accuracyM: accuracyM,
          at: DateTime.now(),
        );
        // Keeps the chip live during the ride too; the origin cannot change
        // mid-ride because it is already set (see _applyOriginFix).
        _applyOriginFix(lat, lng, accuracyM);
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
    // Armed false here, set true by the service when the destination arrival
    // actually speaks. Gates the turnaround default in _defaultOriginToRideEnd.
    await FlutterForegroundTask.saveData(
      key: destinationReachedKey,
      value: false,
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: 1,
      notificationTitle: 'Travel Mode active',
      notificationText:
          '${_name(journey.originStationId)} to '
          '${_name(journey.destinationStationId)}',
      callback: geofenceTaskStartCallback,
    );

    if (result is ServiceRequestSuccess) {
      setState(() => _isRunning = true);
    }
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    setState(() {
      _isRunning = false;
      _windDownLive = false;
    });
    // The dying service isolate also announces this, but a teardown race must
    // not leave a phantom "I'm awake" button or a claimed media session.
    if (_wakeLadderLive) {
      setState(() => _wakeLadderLive = false);
      await _setMediaSession(false);
    }
    await _defaultOriginToRideEnd();
  }

  /// The next ride usually starts where the last one ended (ride out, turn
  /// around, ride back), so after a stop the origin defaults to the finished
  /// ride's destination and the old destination is cleared for a fresh pick.
  /// Before this, the origin kept the morning's value until the app was killed
  /// (both phones, 13 Jul ride test, at the Thane turnaround).
  ///
  /// ONLY for a ride that provably got there: the service records the
  /// destination arrival under [destinationReachedKey], and without it the
  /// default is a guess pointing anywhere. A bench Start/Stop near Shahad
  /// planted Kalyan as the origin this way (13 Jul). A ride stopped early
  /// falls back to the GPS fill instead, and either way the status chip is
  /// re-asked from a real fix, never assumed from the ride.
  Future<void> _defaultOriginToRideEnd() async {
    final reached =
        await FlutterForegroundTask.getData<bool>(key: destinationReachedKey) ??
        false;
    final destinationId = await FlutterForegroundTask.getData<String>(
      key: destinationIdKey,
    );
    if (!mounted) return;
    final destination = reached ? _repo?.stationsById[destinationId] : null;

    setState(() {
      _originId = destination?.id;
      _originField.text = destination?.name ?? '';
      _destinationId = null;
      _destinationField.clear();
    });
    _replan();

    // Chip (and origin, when the ride ended somewhere unproven) from a real
    // fix. The service's last streamed fix is seconds old and free, so prefer
    // it; a cold acquisition indoors can time out, which left a blank origin
    // under a stale chip on the 13 Jul bench. Live GPS stays as the fallback.
    final fix = _lastServiceFix;
    final fresh =
        fix != null &&
        DateTime.now().difference(fix.at) < const Duration(minutes: 3);
    if (fresh && _applyOriginFix(fix.lat, fix.lng, fix.accuracyM)) {
      return;
    }
    await _defaultOriginToNearestStation();
  }

  void _testTts() {
    FlutterForegroundTask.sendDataToTask('test_tts');
  }

  void _testWakeAlert() {
    FlutterForegroundTask.sendDataToTask('test_wake_alert');
  }

  void _testWindDown() {
    FlutterForegroundTask.sendDataToTask('test_wind_down');
  }

  void _wakeAck() {
    FlutterForegroundTask.sendDataToTask('wake_ack');
  }

  void _windDownEndNow() {
    FlutterForegroundTask.sendDataToTask(windDownEndNowId);
  }

  void _windDownExtend() {
    FlutterForegroundTask.sendDataToTask(windDownExtendId);
  }

  /// The service ended the ride itself (wind-down auto-off or its End now
  /// button). Same after-ride path as a manual stop, minus stopping the
  /// service, which is already going down.
  Future<void> _onRideEndedByService() async {
    setState(() {
      _isRunning = false;
      _windDownLive = false;
    });
    if (_wakeLadderLive) {
      setState(() => _wakeLadderLive = false);
      await _setMediaSession(false);
    }
    await _defaultOriginToRideEnd();
  }

  String _name(String stationId) =>
      _repo?.stationsById[stationId]?.name ?? stationId;

  void _holdToEndHint() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Hold to end the journey.')));
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
              _StatusChip(
                state: _gpsState,
                stationName: _nearStationName,
                onTap: _retryLocate,
              ),
              if (_gpsState == _GpsState.unavailable &&
                  !_isRunning &&
                  !_chipTipDismissed) ...[
                const SizedBox(height: 12),
                _ChipTipBanner(
                  onDismiss: () => setState(() => _chipTipDismissed = true),
                ),
              ],
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
              if (_wakeLadderLive)
                // The manual dismiss, and the guaranteed ack fallback when
                // the earphone tap does not route to us. Cream fill: loud
                // enough to find half-asleep, and crimson stays reserved for
                // starting or ending a journey.
                ElevatedButton(
                  key: const Key('im_awake'),
                  onPressed: _wakeAck,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Palette.cream,
                    foregroundColor: Palette.navy,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    "I'm awake",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                )
              else if (_windDownLive)
                // Mirrors the notification's wind-down actions for when the
                // phone is already in hand. Cream like the ack button;
                // crimson stays reserved for starting or ending a journey.
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        key: const Key('wind_down_end_now'),
                        onPressed: _windDownEndNow,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Palette.cream,
                          foregroundColor: Palette.navy,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'End now',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Extend 10 min',
                        onPressed: _windDownExtend,
                        buttonKey: const Key('wind_down_extend'),
                      ),
                    ),
                  ],
                )
              else
                // The three debug triggers, one per feature. "Test" dropped
                // from the labels to fit three abreast without growing the
                // column (the tall debug log lives in the Expanded above).
                Row(
                  children: [
                    Expanded(
                      child: _TestButton(
                        label: 'Announce',
                        onPressed: _isRunning ? _testTts : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Wake alert',
                        onPressed: _isRunning ? _testWakeAlert : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Wind-down',
                        onPressed: _isRunning ? _testWindDown : null,
                      ),
                    ),
                  ],
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

/// A quiet debug-only action. Outlined, dim, never competes with the journey
/// CTA; disabled when no ride (and so no service isolate) is running.
class _TestButton extends StatelessWidget {
  const _TestButton({required this.label, required this.onPressed, this.buttonKey});

  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return OutlinedButton(
      key: buttonKey,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.creamDim(0.75),
        disabledForegroundColor: Palette.creamDim(0.25),
        side: BorderSide(
          color: enabled ? Palette.creamDim(0.3) : Palette.creamDim(0.12),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Text(label),
    );
  }
}

/// The quiet status chip: burgundy surface, never loud, the dot alone carries
/// the GPS state (green = fixed, amber = acquiring, dim = unavailable).
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.state,
    required this.stationName,
    required this.onTap,
  });

  final _GpsState state;
  final String? stationName;

  /// A tap asks for a fresh fix; the copy says so when a fix is what's
  /// missing. The owner of the callback decides when a tap is meaningful.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (dotColor, label, station) = switch (state) {
      _GpsState.locating => (Palette.dotAmber, 'Locating...', null),
      _GpsState.located => (Palette.dotGreen, "You're near: ", stationName),
      _GpsState.unavailable => (
        Palette.creamDim(0.25),
        'Location unavailable. Tap to retry',
        null,
      ),
    };

    return GestureDetector(
      key: const Key('status_chip'),
      onTap: onTap,
      child: _chipBody(dotColor, label, station),
    );
  }

  Widget _chipBody(Color dotColor, String label, String? station) {
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

/// Contextual tip that appears WITH the unavailable state: it teaches the
/// chip's tap exactly when a new user needs it, and leaves on its own the
/// moment a fix lands. Quiet like everything that is not the journey CTA.
class _ChipTipBanner extends StatelessWidget {
  const _ChipTipBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Palette.burgundy,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "Couldn't find your location. Tap the chip above to try again, "
              'or pick your origin by hand.',
              style: TextStyle(fontSize: 13, color: Palette.creamDim(0.8)),
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(foregroundColor: Palette.cream),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// One station picker. 127 stations is too many for an anchored dropdown on a
/// slow phone (13 Jul bench, 3T: the tap raised the keyboard but the menu
/// never showed, and the keyboard overflowed the screen by 84px), so the tap
/// opens a bottom sheet instead: a search field over a lazy list, and the
/// keyboard never appears on this screen at all.
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

  Future<void> _openSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<Station>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Palette.burgundy,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          _StationSearchSheet(label: label, stations: stations),
    );
    if (picked != null) {
      controller.text = picked.name;
      onChanged(picked.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled && stations.isNotEmpty,
      readOnly: true,
      showCursor: false,
      style: const TextStyle(color: Palette.cream),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: Icon(Icons.arrow_drop_down, color: Palette.creamDim(0.6)),
      ),
      onTap: () => _openSheet(context),
    );
  }
}

/// The picker's bottom sheet: search field on top, matching stations below.
/// The list is built lazily, so only the visible rows exist; this is what
/// makes 127 stations instant where the dropdown was not.
class _StationSearchSheet extends StatefulWidget {
  const _StationSearchSheet({required this.label, required this.stations});

  final String label;
  final List<Station> stations;

  @override
  State<_StationSearchSheet> createState() => _StationSearchSheetState();
}

class _StationSearchSheetState extends State<_StationSearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? widget.stations
        : [
            for (final station in widget.stations)
              if (station.name.toLowerCase().contains(query) ||
                  station.code.toLowerCase().contains(query))
                station,
          ];

    // Tall enough to feel like a place to search, short enough that the sheet
    // still reads as a sheet. The keyboard inset keeps the field above it.
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Palette.creamDim(0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                autofocus: true,
                style: const TextStyle(color: Palette.cream),
                decoration: InputDecoration(
                  hintText: 'Search stations',
                  prefixIcon: Icon(Icons.search, color: Palette.creamDim(0.5)),
                ),
                onChanged: (text) => setState(() => _query = text),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        'No stations match.',
                        style: TextStyle(color: Palette.creamDim(0.5)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final station = matches[index];
                        return ListTile(
                          title: Text(
                            station.name,
                            style: const TextStyle(color: Palette.cream),
                          ),
                          trailing: Text(
                            station.code,
                            style: TextStyle(
                              fontSize: 11,
                              color: Palette.creamDim(0.5),
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(station),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
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
    final stops = ride.chain
        .where((s) => s.id != ride.overshootStationId)
        .toList();
    final nameOf = {for (final s in ride.chain) s.id: s.name};
    final changes = ride.interchanges.isEmpty
        ? 'No change of train.'
        : ride.interchanges
              .map((i) {
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
              })
              .join(' ');

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
      // When the rest of the screen (banner up, tall route summary) squeezes
      // this box below the title's own height, the title goes before the box
      // overflows: the stream is the point, the label is not.
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (constraints.maxHeight >= 48) ...[
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
            ],
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
