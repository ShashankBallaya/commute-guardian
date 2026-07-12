// Replays a ride log's FIX lines through RideProgress and prints the
// announcements it would make, so a real ride can be re-judged offline after a
// logic change instead of having to re-ride the line.
//
//   dart run tool/replay_ride.dart <geofence_log.txt>
//
// Reads only `FIX lat ..., lng ..., accuracy ...m` lines, so it works on logs
// from either platform. Announcements it prints are what the CURRENT code would
// say; compare against the `SPEAK` lines already in the log to see what changed.

import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_progress.dart';

/// Mirrors GeofenceChainService's Phase 0 hardcoded Kalyan -> Digha ride.
const _chainIds = [
  'kalyan',
  'thakurli',
  'dombivli',
  'kopar',
  'diva',
  'mumbra',
  'kalwa',
  'thane',
  'digha',
  'airoli',
];
const _destinationId = 'digha';
const _approachRadiusM = {'thane': 1200, 'digha': 1000};
const _arrivalAnnouncements = {
  'thane': 'You have reached Thane. Change here from the Central line to the '
      'Trans Harbour line.',
  'digha': 'You have arrived at your destination, Digha.',
};

final _fixPattern = RegExp(
  r'^(\S+) FIX lat (-?[\d.]+), lng (-?[\d.]+), accuracy (\d+)m',
);

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/replay_ride.dart <geofence_log.txt>');
    exit(64);
  }

  final raw = File('assets/stations/mumbai_suburban.json').readAsStringSync();
  final decoded = jsonDecode(raw);
  final all = <String, Station>{
    for (final s in (decoded is Map ? decoded['stations'] : decoded) as List)
      (s as Map<String, dynamic>)['id'] as String: Station.fromJson(s),
  };

  final ride = RideProgress(
    chain: [for (final id in _chainIds) all[id]!],
    destinationStationId: _destinationId,
    approachRadiusM: _approachRadiusM,
    arrivalAnnouncements: _arrivalAnnouncements,
  );

  var fixes = 0;
  var spoken = 0;
  for (final line in File(args.single).readAsLinesSync()) {
    final m = _fixPattern.firstMatch(line);
    if (m == null) continue;
    fixes++;

    final announcements = ride.onFix(
      lat: double.parse(m.group(2)!),
      lng: double.parse(m.group(3)!),
      accuracyM: double.parse(m.group(4)!),
    );
    for (final a in announcements) {
      spoken++;
      final time = m.group(1)!.split('T').last.split('.').first;
      stdout.writeln('$time  ${a.kind.name.toUpperCase().padRight(9)} '
          '${a.stationId.padRight(9)} ${a.text}');
    }
  }

  stdout.writeln('\n$fixes fixes replayed, $spoken announcements.');
}
