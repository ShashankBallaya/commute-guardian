import 'dart:developer' as dev;

import 'package:flutter_tts/flutter_tts.dart';
import 'package:geofencing_api/geofencing_api.dart';

import '../data/station_repository.dart';
import '../models/station.dart';

/// Phase 0 proof of concept: a hardcoded Dadar -> Kalyan geofence chain.
/// Registers one circular region per station on that segment, speaks the
/// station name on every ENTER event, and logs every event so accuracy can
/// be judged from a real ride (see CLAUDE.md Phase 0 exit criteria).
class GeofenceChainService {
  GeofenceChainService({required this.onLog});

  static const originStationId = 'dadar';
  static const destinationStationId = 'kalyan';
  static const _lineId = 'central_csmt_kalyan';

  final void Function(String message) onLog;

  final FlutterTts _tts = FlutterTts();
  List<Station> _chain = [];

  Future<void> start() async {
    final repo = await StationRepository.load();
    _chain = repo.segment(_lineId, originStationId, destinationStationId);

    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);

    Geofencing.instance.setup(printsDebugLog: true);
    Geofencing.instance.addGeofenceStatusChangedListener(_onStatusChanged);

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
    await Geofencing.instance.start(regions: regions);
  }

  Future<void> stop() async {
    Geofencing.instance.removeGeofenceStatusChangedListener(_onStatusChanged);
    await Geofencing.instance.stop();
    _log('Geofence chain stopped.');
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

  void _log(String message) {
    dev.log(message, name: 'GeofenceChain');
    onLog(message);
  }
}
