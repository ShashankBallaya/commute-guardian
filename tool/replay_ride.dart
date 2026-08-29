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
// (WindDown), HEALTH (RideHealth: GPS_LOST, STALL, WRONG_DIRECTION). Compare
// against the log's own SPEAK/WAKE lines to see what the code change altered.
//
// RideHealth is here because its three edge states are the ones a replay judges
// BEST: all three are meant to stay silent on an ordinary ride, so six real
// logs that produce no HEALTH speech are the strongest false-positive evidence
// available without riding again. It has already earned that twice, catching a
// stall warning fired at an interchange and another fired while the owner was
// walking home from an overshoot.

import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/models/line.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/journey_planner.dart';
import 'package:commute_guardian/services/ride_health.dart';
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
// iOS CallKit, the other half of the call signal. Added the moment the signal
// existed, because a replay blind to it would reproduce an iPhone ride as if
// the ladder had never been suspended, which is the same shape of silent
// wrongness the missing overshoot pins caused.
final _callKitPattern = RegExp(r'^(\S+) Call (started|ended) \(CallKit\)\.$');

const _tick = Duration(seconds: 5);

void main(List<String> args) {
  // The language is a FLAG rather than a positional, so every command in the
  // notes and in docs/ keeps working unchanged and the six canonical replays
  // stay byte-identical by default.
  final languageArg = args.firstWhere(
    (a) => a.startsWith('--lang='),
    orElse: () => '',
  );
  final language = AppLanguage.fromTag(
    languageArg.isEmpty ? null : languageArg.substring('--lang='.length),
  );
  final positional = args.where((a) => !a.startsWith('--')).toList();

  if (positional.isEmpty || positional.length > 3) {
    stderr.writeln(
      'usage: dart run tool/replay_ride.dart <geofence_log.txt> '
      '[origin] [destination] [--lang=hi-IN]',
    );
    exit(64);
  }
  final originId = positional.length > 1 ? positional[1] : 'kalyan';
  final destinationId = positional.length > 2 ? positional[2] : 'thane';

  final doc =
      jsonDecode(
            File('assets/stations/mumbai_suburban.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final stations = (doc['stations'] as List).cast<Map<String, dynamic>>().map(
    Station.fromJson,
  );
  final lines = (doc['lines'] as List).cast<Map<String, dynamic>>().map(
    Line.fromJson,
  );

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
    endpointOnlyWalkInterchanges: [
      for (final pair
          in (doc['endpointOnlyWalkInterchanges'] as List? ?? const []))
        (pair as List).cast<String>(),
    ],
    walkCrossings: {
      for (final entry in (doc['walkCrossings'] as Map? ?? const {}).entries)
        entry.key as String: [
          for (final point in entry.value as List)
            (
              ((point as List)[0] as num).toDouble(),
              (point[1] as num).toDouble(),
            ),
        ],
    },
  ).plan(originId: originId, destinationId: destinationId);

  stdout.writeln('Journey: ${journey.chain.map((s) => s.name).join(' -> ')}\n');

  // Built through the same factories the service uses, deliberately. Listing
  // the fields here by hand is what made this tool go blind: it stopped
  // passing the overshoot pins when d21dc69 moved them out of the chain, so
  // the 22 Jul Kalyan-to-Shahad ride replayed as if the rider had simply
  // stopped after Kalyan. A replay that builds its engines differently from
  // the app is not replaying the app.
  final ride = RideProgress.forJourney(journey, language: language);
  final wake = WakeEscalation.forJourney(journey, language: language);
  final windDown = WindDown.forJourney(journey, language: language);
  final health = RideHealth.forJourney(journey, language: language);

  var fixes = 0;
  var spoken = 0;
  var wakeActions = 0;
  var healthSpoken = 0;
  DateTime? clock;

  String stamp(DateTime t) =>
      t.toIso8601String().split('T').last.split('.').first;

  void printWake(List<WakeAction> actions, DateTime at) {
    for (final action in actions) {
      // A note makes no sound, so it must not inflate the wake-action count
      // the summary line reports. Same rule WindDownNote already follows.
      if (action is! WakeNote) wakeActions++;
      final line = switch (action) {
        Speak(:final text) => 'speak     $text',
        Tone(:final volume) => 'tone      ${volume.toStringAsFixed(1)}',
        StopTone() => 'stop-tone',
        Vibrate() => 'vibrate',
        HardStop() => 'HARD STOP (ceiling)',
        WakeNote(:final message) => 'note      $message',
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

  void printHealth(List<RideHealthAction> actions, DateTime at) {
    for (final action in actions) {
      final line = switch (action) {
        RideHealthSpeak(:final text) => 'speak     $text',
        RideHealthNote(:final reason) => 'note      $reason',
      };
      if (action is RideHealthSpeak) healthSpoken++;
      stdout.writeln('${stamp(at)}  HEALTH    $line');
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
      printHealth(health.onTick(clock!), clock!);
    }
  }

  for (final line in File(args.first).readAsLinesSync()) {
    final interruption = _interruptionPattern.firstMatch(line);
    if (interruption != null) {
      final at = DateTime.parse(interruption.group(1)!);
      tickUpTo(at);
      final began = interruption.group(2)!.startsWith('interrupted');
      stdout.writeln('${stamp(at)}  CALL      ${began ? 'started' : 'ended'}');
      printWake(wake.onCallStateChanged(inCall: began, now: at), at);
      continue;
    }

    final callKit = _callKitPattern.firstMatch(line);
    if (callKit != null) {
      final at = DateTime.parse(callKit.group(1)!);
      tickUpTo(at);
      final began = callKit.group(2)! == 'started';
      stdout.writeln(
        '${stamp(at)}  CALL      ${began ? 'started' : 'ended'} (CallKit)',
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
    // The same call the service makes right after RideProgress, and in the same
    // order: the ladder's cursor has to be told where the train actually is or
    // a ride joined past an interchange keeps a ladder that can never arm.
    printWake(wake.localize(ride.reachedIndex), at);
    printHealth(
      health.onFix(
        at,
        // ONE definition of usable, read off the engine, exactly as the service
        // reads it rather than repeating the number.
        usable: accuracyM <= ride.maxAccuracyM,
        lat: lat,
        lng: lng,
      ),
      at,
    );
    for (final a in announcements) {
      spoken++;
      stdout.writeln(
        '${stamp(at)}  ${a.kind.name.toUpperCase().padRight(9)} '
        '${a.stationId.padRight(9)} ${a.text}',
      );
      printWake(wake.onStationEvent(a, at), at);
      printWindDown(windDown.onStationEvent(a, at), at);
      // The same two journey facts the service passes, from the same journey.
      // Wiring these by hand differently from the service is precisely how this
      // tool went blind on the overshoot pins.
      printHealth(
        health.onStationPassed(
          at,
          stationId: a.stationId,
          changeHere: journey.interchanges.any(
            (i) => i.stationId == a.stationId,
          ),
          endsWatch:
              a.kind == AnnouncementKind.overshoot ||
              (a.kind == AnnouncementKind.arrival &&
                  a.stationId == journey.destinationStationId),
        ),
        at,
      );
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
    '$wakeActions wake actions, $healthSpoken health warnings.',
  );
}
