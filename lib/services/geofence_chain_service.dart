import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geofencing_api/geofencing_api.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/station_repository.dart';
import '../models/station.dart';

/// Phase 0 proof of concept: a hardcoded Dombivli -> Shahad geofence chain.
/// Registers one circular region per station on that segment, speaks the
/// station name on every ENTER event, and logs every event so accuracy can
/// be judged from a real ride (see CLAUDE.md Phase 0 exit criteria).
class GeofenceChainService {
  GeofenceChainService({required this.onLog});

  static const originStationId = 'shahad';
  static const destinationStationId = 'dombivli';
  static const _lineId = 'central_csmt_kalyan';

  final void Function(String message) onLog;

  final FlutterTts _tts = FlutterTts();
  List<Station> _chain = [];
  File? _logFile;
  StreamSubscription<fl.Location>? _rawLocationSub;

  Future<void> start() async {
    _logFile = await _createLogFile();

    final locationAlways = await Permission.locationAlways.status;
    final ignoringBatteryOpt =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    _log(
      'Permission state at start: locationAlways=$locationAlways, '
      'ignoringBatteryOptimizations=$ignoringBatteryOpt',
    );

    final repo = await StationRepository.load();
    _chain = repo.segment(_lineId, originStationId, destinationStationId);

    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);

    Geofencing.instance.setup(printsDebugLog: true);
    Geofencing.instance.addGeofenceStatusChangedListener(_onStatusChanged);
    Geofencing.instance.addGeofenceErrorCallbackListener(_onGeofenceError);

    final regions = _chain
        .map(
          (station) => GeofenceRegion.circular(
            id: station.id,
            data: station.name,
            center: LatLng(station.lat, station.lng),
            radius: station.radiusM.toDouble(),
          ),
        )
        .toSet();

    _log(
      'Starting geofence chain: ${_chain.map((s) => s.name).join(' -> ')}',
    );

    try {
      // Independent of geofencing_api's own internal fl_location stream:
      // logs every raw fix (including ones geofencing_api would silently
      // drop for low accuracy) so a real ride's log proves whether GPS
      // fixes are arriving at all, and at what accuracy.
      _rawLocationSub = fl.FlLocation.getLocationStream(
        accuracy: fl.LocationAccuracy.navigation,
      ).listen(_onRawLocation, onError: _onRawLocationError);

      await Geofencing.instance.start(regions: regions);
    } catch (error) {
      _log('Geofencing chain failed to start: $error');
    }
  }

  /// Debug-only: speaks a test line through the same [FlutterTts] instance
  /// and isolate real station announcements use, without needing a real or
  /// mocked GPS fix to trigger a geofence ENTER.
  Future<void> testAnnounce() async {
    _log('Test announcement requested.');
    await _tts.speak(
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
    _log('Geofence chain stopped.');
    _logFile = null;
  }

  /// One file per Travel Mode session, on Android under the app's
  /// external files dir (Android/data/<package>/files), pullable with
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

    final station = _chain.firstWhere((s) => s.id == region.id);
    _log(
      'ENTER ${station.name} '
      '(fix ${location.latitude.toStringAsFixed(5)}, '
      '${location.longitude.toStringAsFixed(5)}, '
      'accuracy ${location.accuracy.toStringAsFixed(0)}m)',
    );

    final announcement = station.id == destinationStationId
        ? 'You have arrived at ${station.name}.'
        : 'Now approaching ${station.name}.';
    await _tts.speak(announcement);
  }

  void _onRawLocation(fl.Location location) {
    _log(
      'FIX lat ${location.latitude.toStringAsFixed(5)}, '
      'lng ${location.longitude.toStringAsFixed(5)}, '
      'accuracy ${location.accuracy.toStringAsFixed(0)}m, '
      'mock ${location.isMock}',
    );
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
