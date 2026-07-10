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

/// Phase 0 proof of concept: a hardcoded Kalyan -> Digha geofence chain.
/// This ride spans two lines: Central Main down-line Kalyan to Thane, then a
/// change at Thane onto the Trans-Harbour line to Digha (the alighting point).
/// The chain is defined in travel order by the `harbour_ride_kalyan_digha`
/// line. Registers a circular region per station on that chain (plus a second,
/// larger outer approach fence for the interchange and destination), speaks an
/// announcement on every ENTER event, and logs every event so accuracy can be
/// judged from a real ride (see CLAUDE.md Phase 0 exit criteria).
class GeofenceChainService {
  GeofenceChainService({required this.onLog});

  static const originStationId = 'kalyan';

  /// Alighting point: the ENTER here is announced as "arrived".
  static const destinationStationId = 'digha';

  /// Last fence registered, one station past the destination on the
  /// Trans-Harbour line. Kept as an overshoot safety net so a missed Digha
  /// alight still gets an announcement.
  static const _chainEndStationId = 'airoli';

  static const _lineId = 'harbour_ride_kalyan_digha';

  /// Two-stage announcement stations: each id here gets a second, larger
  /// outer "approach" fence (radius in meters) in addition to its normal
  /// station fence, so the ride announces the station is coming BEFORE the
  /// train reaches the platform. Used for the points the rider has to act on
  /// (the Thane interchange and the Digha destination), giving a heads-up
  /// while there is still time to get to the doors.
  static const _approachRadiusM = <String, int>{
    'thane': 1200,
    'digha': 1000,
  };

  /// Spoken when the inner station fence is entered for a two-stage station
  /// (the "you have reached / arrived" stage). Stations not listed here just
  /// get the default "Now approaching ..." ping on their single fence.
  static const _arrivalAnnouncements = <String, String>{
    'thane':
        'You have reached Thane. Change here from the Central line to the '
        'Trans Harbour line. Get off the train, go to platform number 9, 10, '
        'or 10 A, then board the Trans Harbour train to continue to your '
        'destination.',
    destinationStationId: 'You have arrived at your destination, Digha.',
  };

  /// Marks the outer approach fence for a two-stage station, keeping its
  /// region id distinct from the inner station fence.
  static const _approachSuffix = '#approach';

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
    _chain = repo.segment(_lineId, originStationId, _chainEndStationId);

    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);
    if (Platform.isAndroid) {
      // flutter_tts defaults to QUEUE_FLUSH on Android: a second speak()
      // cuts off whatever is still playing. If a GPS gap drops the first
      // fix inside both of a two-stage station's fences, both ENTERs speak
      // back-to-back and the long interchange script could be flushed
      // mid-sentence by the short approach ping. QUEUE_ADD (1) plays each
      // announcement in full, in order. iOS queues natively and does not
      // implement setQueueMode, hence the platform guard.
      await _tts.setQueueMode(1);
    }

    Geofencing.instance.setup(printsDebugLog: true);
    Geofencing.instance.addGeofenceStatusChangedListener(_onStatusChanged);
    Geofencing.instance.addGeofenceErrorCallbackListener(_onGeofenceError);

    final regions = <GeofenceRegion>{};
    for (final station in _chain) {
      regions.add(
        GeofenceRegion.circular(
          id: station.id,
          data: station.name,
          center: LatLng(station.lat, station.lng),
          radius: station.radiusM.toDouble(),
        ),
      );
      final approachRadius = _approachRadiusM[station.id];
      if (approachRadius != null) {
        regions.add(
          GeofenceRegion.circular(
            id: '${station.id}$_approachSuffix',
            data: station.name,
            center: LatLng(station.lat, station.lng),
            radius: approachRadius.toDouble(),
          ),
        );
      }
    }

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
  /// external files dir (`Android/data/<package>/files`), pullable with
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

    final isApproach = region.id.endsWith(_approachSuffix);
    final stationId = isApproach
        ? region.id.substring(0, region.id.length - _approachSuffix.length)
        : region.id;
    final station = _chain.firstWhere((s) => s.id == stationId);

    _log(
      'ENTER ${isApproach ? 'APPROACH' : 'ARRIVE'} ${station.name} '
      '(fix ${location.latitude.toStringAsFixed(5)}, '
      '${location.longitude.toStringAsFixed(5)}, '
      'accuracy ${location.accuracy.toStringAsFixed(0)}m)',
    );

    // Outer fence: heads-up ping. Inner fence: the custom "reached / arrived"
    // line for two-stage stations, else the same approaching ping for a plain
    // single-fence station.
    final announcement = isApproach
        ? 'Now approaching ${station.name}.'
        : _arrivalAnnouncements[station.id] ??
            'Now approaching ${station.name}.';
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
