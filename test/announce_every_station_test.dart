import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Name every station", wired 12 Aug 2026 after a Settings audit found it was
/// a dead control that lied in words.
///
/// It was written to the store, read back into AppSettings, and consumed by
/// NOTHING: the raw key appeared in exactly one file. The row promised "Off
/// announces only your stop, and still wakes you" and every station was
/// announced anyway. That is worse than the wake toggle deleted on 11 Aug,
/// because that one changed nothing silently and this one made a claim.
///
/// Read from the SOURCE, like the pulse-vibrate guard next door, because the
/// suppression lives in the service isolate and `GeofenceChainService` reaches
/// plugins on construction, so it cannot be built under the test binding.
void main() {
  final service = File(
    'lib/services/geofence_chain_service.dart',
  ).readAsStringSync();

  /// Comments stripped, because this file argues about the thing it does and
  /// the argument names every symbol the guard looks for. Five source-reading
  /// guards in this project have matched prose that merely looked like code.
  final code = service
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  group('THE VOICE IS WITHHELD, NEVER THE EVENT', () {
    test('the suppression sits at the SPEAK step, not at the announcement', () {
      // WakeEscalation reads these announcements to know where the train is,
      // WindDown reads them to know the ride arrived, and RideProgress ratchets
      // on them. Dropping the announcement would silence the alarm along with
      // the commentary, which is the opposite of what the row promises.
      final loop = code.substring(code.indexOf('for (final announcement in'));

      expect(
        loop.contains('_announceEveryStation'),
        isTrue,
        reason: 'the flag must be consulted inside the announcement loop',
      );
      expect(
        loop.indexOf('_log('),
        lessThan(loop.indexOf('_announceEveryStation')),
        reason: 'the SPEAK line is logged BEFORE anything is withheld, because '
            'replay_ride.dart parses it to reconstruct a ride',
      );
    });

    test('a withheld line is logged, so the ride log cannot lie by omission', () {
      expect(code.contains('SPEAK withheld'), isTrue);
    });
  });

  group('WHAT "ONLY YOUR STOP" IS STILL ALLOWED TO SAY', () {
    // Every one of these is a station the rider has to DO something at. The
    // switch turns off commentary, never instructions.
    final guard = code.substring(
      code.indexOf('bool _mustAlwaysSpeak'),
      code.indexOf('bool _wakeEnabled'),
    );

    test('an overshoot always speaks, because it is the safety net', () {
      expect(guard.contains('AnnouncementKind.overshoot'), isTrue);
    });

    test('the destination always speaks, because it IS the stop', () {
      expect(guard.contains('destinationStationId'), isTrue);
    });

    test('AN INTERCHANGE ALWAYS SPEAKS, and it is the one easy to forget', () {
      // A rider who misses a train change is as stranded as one who misses
      // their stop, and this switch was never about instructions.
      expect(guard.contains('interchanges'), isTrue);
    });

    test('an unknown journey speaks everything, which is the safe side', () {
      expect(
        guard.contains('if (journey == null) return true;'),
        isTrue,
        reason: 'no journey means no way to know what matters, so say it all',
      );
    });
  });

  group('IT CROSSES THE ISOLATE AND IS READ ONCE', () {
    final handler = File(
      'lib/foreground/geofence_task_handler.dart',
    ).readAsStringSync();

    test('the service reads it from the STORE, like the language', () {
      expect(handler.contains('announceEveryStationServiceKey'), isTrue);
    });

    test('A MISSING KEY MEANS EVERY STATION, which is the safe default', () {
      // An older store, or a service the OS recreated mid-ride, must cost the
      // rider extra announcements and never their stop.
      // Whitespace-insensitive on purpose: what matters is that the read falls
      // back to true, not how the formatter chose to wrap it.
      final read = handler
          .substring(handler.indexOf('announceEveryStation:'))
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(
        read.startsWith(
          'announceEveryStation: await FlutterForegroundTask.getData<bool>( '
          'key: announceEveryStationServiceKey, ) ?? true,',
        ),
        isTrue,
        reason: 'a missing key must mean every station',
      );
    });
  });
}
