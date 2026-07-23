// Replays a ride log through the three pure engines and prints what each
// would do, so a real ride can be re-judged offline after a logic change
// instead of having to re-ride the line.
//
//   dart run tool/replay_ride.dart <geofence_log.txt> [origin] [destination]
//
// Origin and destination default to the ride the app currently runs. Feeds:
//   - `FIX ...` lines into RideProgress (announcements), WakeEscalation and
//     WindDown, with speed when the log carries it (older logs may not).
//   - `Audio session interrupted/ended` lines into WakeEscalation's call
//     handling (locked decision 8), reproducing a real mid-ride call.
//   - A synthesized 5 second tick between log lines, standing in for the
//     service's onRepeatEvent, so ladder rungs and countdowns fire at the
//     times they would have fired on the ride.
//
// Nothing acknowledges the wake ladder in a replay, so an armed ladder
// climbs to its ceiling exactly as it would for a sleeping rider.
//
// Output prefixes: SPEAK (RideProgress), WAKE (WakeEscalation), WIND_DOWN
// (WindDown). Compare against the log's own SPEAK/WAKE lines to see what
// the code change altered.

import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/models/line.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/journey_planner.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:commute_guardian/services/wake_escalation.dart';
import 'package:commute_guardian/services/wind_down.dart';

final _fixPattern = RegExp(
  r'^(\S+) FIX lat (-?[\d.]+), lng (-?[\d.]+), accuracy (\d+)m'
  r'(?:, speed (-?[\d.]+)m/s)?',
);
// Anchored at the end so the "by our own audio, ignored" variants never match.
// Those are the interruptions the app itself withheld from the wake engine
// (SelfAudioInterruptionFilter); treating them as calls here would make replay
// disagree with the ride it is meant to reproduce.
final _interruptionPattern = RegExp(
  r'^(\S+) Audio session (interrupted \(call or other audio\)|'
  r'interruption ended)\.$',
);

const _tick = Duration(seconds: 5);

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
    throughServices: [
      for (final pair in (doc['throughServices'] as List? ?? const []))
        (pair as List).cast<String>(),
    ],
    walkInterchanges: [
      for (final pair in (doc['walkInterchanges'] as List? ?? const []))
        (pair as List).cast<String>(),
    ],
  ).plan(originId: originId, destinationId: destinationId);

  stdout.writeln('Journey: ${journey.chain.map((s) => s.name).join(' -> ')}\n');

  // Built through the same factories the service uses, deliberately. Listing
  // the fields here by hand is what made this tool go blind: it stopped
  // passing the overshoot pins when d21dc69 moved them out of the chain, so
  // the 22 Jul Kalyan-to-Shahad ride replayed as if the rider had simply
  // stopped after Kalyan. A replay that builds its engines differently from
  // the app is not replaying the app.
  final ride = RideProgress.forJourney(journey);
  final wake = WakeEscalation.forJourney(journey);
  final windDown = WindDown.forJourney(journey);

  var fixes = 0;
  var spoken = 0;
  var wakeActions = 0;
  DateTime? clock;

  String stamp(DateTime t) =>
      t.toIso8601String().split('T').last.split('.').first;

  void printWake(List<WakeAction> actions, DateTime at) {
    for (final action in actions) {
      wakeActions++;
      final line = switch (action) {
        Speak(:final text) => 'speak     $text',
        Tone(:final volume) => 'tone      ${volume.toStringAsFixed(1)}',
        StopTone() => 'stop-tone',
        Vibrate() => 'vibrate',
        HardStop() => 'HARD STOP (ceiling)',
      };
      stdout.writeln('${stamp(at)}  WAKE      $line');
    }
  }

  void printWindDown(List<WindDownAction> actions, DateTime at) {
    for (final action in actions) {
      final line = switch (action) {
        WindDownSpeak(:final text) => 'speak     $text',
        WindDownEnd() => 'END TRAVEL MODE',
        WindDownNote(:final reason) => 'note      $reason',
      };
      stdout.writeln('${stamp(at)}  WIND_DOWN $line');
    }
  }

  // Stands in for the service's 5 second onRepeatEvent between log lines.
  void tickUpTo(DateTime target) {
    if (clock == null) {
      clock = target;
      return;
    }
    while (target.difference(clock!) >= _tick) {
      clock = clock!.add(_tick);
      printWake(wake.onTick(clock!), clock!);
      printWindDown(windDown.onTick(clock!), clock!);
    }
  }

  for (final line in File(args.first).readAsLinesSync()) {
    final interruption = _interruptionPattern.firstMatch(line);
    if (interruption != null) {
      final at = DateTime.parse(interruption.group(1)!);
      tickUpTo(at);
      final began = interruption.group(2)!.startsWith('interrupted');
      stdout.writeln(
        '${stamp(at)}  CALL      ${began ? 'started' : 'ended'}',
      );
      printWake(wake.onCallStateChanged(inCall: began, now: at), at);
      continue;
    }

    final m = _fixPattern.firstMatch(line);
    if (m == null) continue;
    fixes++;
    final at = DateTime.parse(m.group(1)!);
    tickUpTo(at);

    final lat = double.parse(m.group(2)!);
    final lng = double.parse(m.group(3)!);
    final accuracyM = double.parse(m.group(4)!);
    final speedMps = double.tryParse(m.group(5) ?? '') ?? 0;

    final announcements = ride.onFix(lat: lat, lng: lng, accuracyM: accuracyM);
    for (final a in announcements) {
      spoken++;
      stdout.writeln('${stamp(at)}  ${a.kind.name.toUpperCase().padRight(9)} '
          '${a.stationId.padRight(9)} ${a.text}');
      printWake(wake.onStationEvent(a, at), at);
      printWindDown(windDown.onStationEvent(a, at), at);
    }

    printWake(
      wake.onFix(
        lat: lat,
        lng: lng,
        accuracyM: accuracyM,
        speedMps: speedMps,
        now: at,
      ),
      at,
    );
    printWindDown(
      windDown.onFix(
        lat: lat,
        lng: lng,
        accuracyM: accuracyM,
        speedMps: speedMps,
        now: at,
      ),
      at,
    );
  }

  stdout.writeln(
    '\n$fixes fixes replayed, $spoken announcements, '
    '$wakeActions wake actions.',
  );
}
