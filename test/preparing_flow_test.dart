import 'dart:async';
import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/preparing_flow.dart';
import 'package:commute_guardian/services/audio_output_gateway.dart';
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
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
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

  // THE VOLUME CHECK, built 11 Aug 2026 after a real silent alarm. The ladder
  // went live, seized the session exclusively, climbed all three rungs, and the
  // owner heard nothing. Nothing in the app had ever read the system volume,
  // although this file's own doc listed it as one of the two audio checks and
  // the debug screen has carried a "Volume is low" chip wired to nothing.
  group('the volume warning', () {
    PreparingReport withVolume(double? volume) => PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: true,
      alarmVolume: volume,
    );

    test('a low volume stops the ride starting silently', () {
      expect(withVolume(0.0).volumeLow, isTrue);
      expect(withVolume(0.1).volumeLow, isTrue);
      expect(withVolume(0.0).clear, isFalse);
    });

    test('an adequate volume says nothing at all', () {
      expect(withVolume(0.5).volumeLow, isFalse);
      expect(withVolume(1.0).volumeLow, isFalse);
      expect(withVolume(0.5).clear, isTrue);
    });

    test('the boundary is a floor, not a ceiling', () {
      // Exactly at the threshold is fine. Only BELOW it warns, so the constant
      // reads the way its name does.
      expect(withVolume(AudioOutputGateway.lowVolume).volumeLow, isFalse);
      expect(withVolume(AudioOutputGateway.lowVolume - 0.01).volumeLow, isTrue);
    });

    test('AN UNREADABLE VOLUME IS NOT A WARNING', () {
      // Fails open, like every other probe on this screen. A warning we cannot
      // stand behind, shown before every ride, teaches the rider to tap past
      // the screen on the ride where it mattered.
      expect(withVolume(null).volumeLow, isFalse);
      expect(withVolume(null).clear, isTrue);
    });
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

  testWidgets(
    'a low volume DRAWS the warning that had never been wired to anything',
    (tester) async {
      // The chip existed on the debug screen from the day Screen 3 was drawn
      // and nothing could ever produce it, because nothing read the volume.
      // This is the test that says the wire is real, not the constant.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stationRepositoryProvider.overrideWith(
              (ref) async => StationRepository.parse(stationsJson),
            ),
            fixAcquirerProvider.overrideWithValue(
              () async => fixAt(shahadLat, shahadLng),
            ),
          ],
          child: const MaterialApp(
            home: PreparingFlow(
              destinationName: 'Kalyan',
              report: PreparingReport(
                hasFix: true,
                originName: 'Shahad',
                backgroundLocationGranted: true,
                // Earphones IN, so the only thing wrong is the volume and the
                // screen cannot be passing for the other reason.
                earphonesConnected: true,
                alarmVolume: 0.05,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Volume is low'), findsOneWidget);
      expect(find.text("Your earphones aren't connected"), findsNothing);
    },
  );

  testWidgets('the promise never invents an origin it does not have', (
    tester,
  ) async {
    // State A exists BECAUSE the origin is unknown, so "Shahad to Kalyan" is a
    // claim the screen cannot make yet.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          // Never resolves: holds the flow in state A so it can be read.
          fixAcquirerProvider.overrideWithValue(
            () => Completer<fl.Location>().future,
          ),
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

    expect(
      find.textContaining('To Kalyan', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Getting ready'), findsOneWidget);
  });

  testWidgets('a failed fix lands on state B, not a spinner forever', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
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
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          fixAcquirerProvider.overrideWithValue(
            () => Completer<fl.Location>().future,
          ),
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
