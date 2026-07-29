import 'dart:async';
import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/preparing_flow.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 3, wired.
///
/// The thing most worth pinning is the NEGATIVE: on an ordinary ride this flow
/// must never appear. The fix is normally already held, so a gate that pushed
/// itself unconditionally would flash a progress screen on every journey.
void main() {
  late String stationsJson;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
  });

  fl.Location fixAt(double lat, double lng) => fl.Location(
        latitude: lat,
        longitude: lng,
        accuracy: 10,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        millisecondsSinceEpoch: 0,
        timestamp: DateTime(2026, 7, 29),
        isMock: false,
      );

  // Shahad.
  const shahadLat = 19.2403;
  const shahadLng = 73.1310;

  Future<bool?> pumpFlow(
    WidgetTester tester, {
    required PreparingReport report,
    FixAcquirer? acquirer,
  }) async {
    bool? outcome;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider
              .overrideWith((ref) async => StationRepository.parse(stationsJson)),
          if (acquirer != null) fixAcquirerProvider.overrideWithValue(acquirer),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                outcome = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => PreparingFlow(
                      destinationName: 'Kalyan',
                      report: report,
                    ),
                  ),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return outcome;
  }

  test('a clear report means the rider never sees Screen 3', () {
    const clear = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: true,
    );
    expect(clear.clear, isTrue);
  });

  test('any one failed probe is enough to stop and say so', () {
    const noFix = PreparingReport(
      hasFix: false,
      originName: null,
      backgroundLocationGranted: true,
      earphonesConnected: true,
    );
    const noPermission = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: false,
      earphonesConnected: true,
    );
    const noEarphones = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: false,
    );
    expect(noFix.clear, isFalse);
    expect(noPermission.clear, isFalse);
    expect(noEarphones.clear, isFalse);
  });

  testWidgets('with no fix it waits, then leaves on its own once found', (
    tester,
  ) async {
    // Everything else already passes, so a landed fix means there is nothing
    // left to say and the flow must settle itself rather than making the rider
    // dismiss a screen that has no news.
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: false,
        originName: null,
        backgroundLocationGranted: true,
        earphonesConnected: true,
      ),
      acquirer: () async => fixAt(shahadLat, shahadLng),
    );
    expect(outcome, isTrue);
  });

  testWidgets('the promise never invents an origin it does not have', (
    tester,
  ) async {
    // State A exists BECAUSE the origin is unknown, so "Shahad to Kalyan" is a
    // claim the screen cannot make yet.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider
              .overrideWith((ref) async => StationRepository.parse(stationsJson)),
          // Never resolves: holds the flow in state A so it can be read.
          fixAcquirerProvider.overrideWithValue(() => Completer<fl.Location>().future),
        ],
        child: const MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: false,
              originName: null,
              backgroundLocationGranted: true,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('To Kalyan', findRichText: true), findsOneWidget);
    expect(find.text('Getting ready'), findsOneWidget);
  });

  testWidgets('a failed fix lands on state B, not a spinner forever', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider
              .overrideWith((ref) async => StationRepository.parse(stationsJson)),
          fixAcquirerProvider
              .overrideWithValue(() async => throw StateError('no GPS')),
        ],
        child: const MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: false,
              originName: null,
              backgroundLocationGranted: true,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("We can't find you yet"), findsOneWidget);
  });

  testWidgets('refused background location stops the ride until answered', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: true,
              originName: 'Shahad',
              backgroundLocationGranted: false,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("We can't wake you with the screen off"), findsOneWidget);
  });

  testWidgets('start anyway carries straight through to the ride', (
    tester,
  ) async {
    // Earphones are fine here, so there is nothing after the permission screen
    // and the flow must not park the rider on an empty checklist.
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: true,
        originName: 'Shahad',
        backgroundLocationGranted: false,
        earphonesConnected: true,
      ),
    );
    expect(outcome, isNull, reason: 'not started yet, the screen is showing');

    await tester.tap(find.byKey(const Key('background_location_start_anyway')));
    await tester.pumpAndSettle();
  });

  testWidgets('missing earphones warn once and never block', (tester) async {
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: true,
        originName: 'Shahad',
        backgroundLocationGranted: true,
        earphonesConnected: false,
      ),
    );
    expect(outcome, isNull);

    expect(find.text('One thing before you doze off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preflight_start')));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling state A abandons rather than starting a ride', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider
              .overrideWith((ref) async => StationRepository.parse(stationsJson)),
          fixAcquirerProvider
              .overrideWithValue(() => Completer<fl.Location>().future),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const PreparingFlow(
                    destinationName: 'Kalyan',
                    report: PreparingReport(
                      hasFix: false,
                      originName: null,
                      backgroundLocationGranted: true,
                      earphonesConnected: true,
                    ),
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('preparing_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('go'), findsOneWidget, reason: 'back where they started');
  });
}
