// Replays a ride log's FIX lines through RideProgress and prints the
// announcements it would make, so a real ride can be re-judged offline after a
// logic change instead of having to re-ride the line.
//
//   dart run tool/replay_ride.dart <geofence_log.txt> [origin] [destination]
//
// Origin and destination default to the ride the app currently runs. Reads only
// `FIX lat ..., lng ..., accuracy ...m` lines, so it works on logs from either
// platform. Announcements it prints are what the CURRENT code would say; compare
// against the `SPEAK` lines already in the log to see what changed.

import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/models/line.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/journey_planner.dart';
import 'package:commute_guardian/services/ride_progress.dart';

final _fixPattern = RegExp(
  r'^(\S+) FIX lat (-?[\d.]+), lng (-?[\d.]+), accuracy (\d+)m',
);

void main(List<String> args) {
  if (args.isEmpty || args.length > 3) {
    stderr.writeln(
      'usage: dart run tool/replay_ride.dart <geofence_log.txt> '
      '[origin] [destination]',
    );
    exit(64);
  }
  final originId = args.length > 1 ? args[1] : 'kalyan';
  final destinationId = args.length > 2 ? args[2] : 'thane';

  final doc = jsonDecode(
    File('assets/stations/mumbai_suburban.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final stations = (doc['stations'] as List)
      .cast<Map<String, dynamic>>()
      .map(Station.fromJson);
  final lines =
      (doc['lines'] as List).cast<Map<String, dynamic>>().map(Line.fromJson);

  final journey = JourneyPlanner(
    stationsById: {for (final s in stations) s.id: s},
    linesById: {for (final l in lines) l.id: l},
  ).plan(originId: originId, destinationId: destinationId);

  stdout.writeln('Journey: ${journey.chain.map((s) => s.name).join(' -> ')}\n');

  final ride = RideProgress(
    chain: journey.chain,
    destinationStationId: journey.destinationStationId,
    approachRadiusM: journey.approachRadiusM,
    arrivalAnnouncements: journey.arrivalAnnouncements,
  );

  var fixes = 0;
  var spoken = 0;
  for (final line in File(args.first).readAsLinesSync()) {
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
