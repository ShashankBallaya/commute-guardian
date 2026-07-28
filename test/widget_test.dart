import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';

import 'support/fake_ride_service_client.dart';

/// Brings the screen up with the real station network loaded.
///
/// The repository is read straight off disk rather than through `rootBundle`,
/// because the asset bundle does real I/O and real I/O cannot make progress
/// inside the fake-async zone that `pump` runs in: the pickers would come up
/// empty and disabled, and the whole screen would be untestable.
Future<void> _pumpScreen(
  WidgetTester tester, {
  AppDatabase? history,
  FakeRideServiceClient? service,
}) async {
  final raw = File(StationRepository.assetPath).readAsStringSync();
  // The single ProviderScope for every widget test. Overrides land here, so no
  // individual test has to know that Riverpod exists
  // (docs/design/riverpod-adoption.md).
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stationRepositoryProvider
            .overrideWith((ref) async => StationRepository.parse(raw)),
        // Fails like an indoor timeout does. The real plugin cannot answer in
        // the fake-async zone; without this the chip hangs on "Locating...".
        fixAcquirerProvider
            .overrideWithValue(() async => throw StateError('no GPS under test')),
        // No isolate under test, so no plugin channels either.
        rideServiceClientProvider
            .overrideWithValue(service ?? FakeRideServiceClient()),
        // Always in-memory: the real factory needs path_provider, which no
        // widget test can answer.
        //
        // overrideWith, not overrideWithValue, and both halves matter. Lazy,
        // so a test that never opens history never builds a database (the
        // screen used to get that from a `late final` field). And closed on
        // teardown, which overrideWithValue cannot do because it skips the
        // create function and therefore the onDispose with it. Without this,
        // drift warns about a second instance of the database class, which is
        // its way of saying two connections could race on one file.
        appDatabaseProvider.overrideWith((ref) {
          final db = history ?? AppDatabase.inMemory();
          ref.onDispose(db.close);
          return db;
        }),
        // These tests are about the ride screen, so they start past
        // onboarding. The gate itself is tested in onboarding_test.dart.
        onboardingSeenProvider.overrideWith((ref) async => true),
      ],
      child: const CommuteGuardianDebugApp(),
    ),
  );
  await tester.pumpAndSettle();

  // Sanity check that the station data actually arrived, since almost every
  // test below is meaningless without it. Skipped when a ride is already
  // running: the pickers are then disabled ON PURPOSE, because changing the
  // ride mid-ride would leave the service on the old one.
  if (!(service?.running ?? false)) {
    final origin = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Origin'),
    );
    expect(
      origin.enabled,
      isTrue,
      reason: 'station data never loaded, so the pickers are disabled',
    );
  }
}

/// Picks [station] in the [label] picker: the field opens a search sheet, and
/// searching is the only way to reach a row here, the rest are never built.
Future<void> _pick(WidgetTester tester, String label, String station) async {
  await tester.tap(find.widgetWithText(TextField, label));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Search stations'),
    station,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, station));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ride cannot be started until one has been picked', (
    tester,
  ) async {
    await _pumpScreen(tester);

    expect(find.text('Pick an origin and a destination.'), findsOneWidget);

    // Starting the service with no journey would run a ride nobody chose. The
    // button stays dead until JourneyPlanner has actually planned one.
    final start = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start journey'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('the Sarvam greeting bench flag exists and defaults OFF', (
    tester,
  ) async {
    await _pumpScreen(tester);

    // Off by default is the safety contract: with the switch untouched the
    // Start path is byte-identical to the proven TTS welcome.
    final greetingSwitch = tester.widget<Switch>(
      find.byKey(const Key('sarvam_greeting_switch')),
    );
    expect(greetingSwitch.value, isFalse);
  });

  testWidgets('picking an origin and destination plans and offers the ride', (
    tester,
  ) async {
    await _pumpScreen(tester);

    await _pick(tester, 'Origin', 'Kalyan');
    await _pick(tester, 'Destination', 'Thane');

    // The planned ride is shown before Start, so a wrong pick is caught on the
    // platform rather than thirty minutes into the wrong train.
    expect(find.textContaining('Kalyan → Thakurli'), findsOneWidget);
    expect(find.textContaining('No change of train.'), findsOneWidget);

    final start = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start journey'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('the open search sheet says which end it is setting', (
    tester,
  ) async {
    await _pumpScreen(tester);

    // The sheet covers the field it came from, so without this the only thing
    // telling you whether you are setting where you are or where you are going
    // is hidden behind the sheet.
    await tester.tap(find.widgetWithText(TextField, 'Destination'));
    await tester.pumpAndSettle();

    // Scoped to the sheet: the field underneath carries the same word, and
    // that one is exactly the label the sheet is covering up.
    final labelInSheet = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Destination'),
    );
    expect(labelInSheet, findsOneWidget);

    // And it keeps saying so once the hint text has gone.
    await tester.enterText(
      find.widgetWithText(TextField, 'Search stations'),
      'Kal',
    );
    await tester.pumpAndSettle();
    expect(labelInSheet, findsOneWidget);
  });

  testWidgets('a station is reachable by its Devanagari name', (tester) async {
    await _pumpScreen(tester);

    await tester.tap(find.widgetWithText(TextField, 'Destination'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search stations'),
      'कल्याण',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Kalyan'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'Kalyan'),
      findsOneWidget,
      reason: 'typing the Hindi name did not pick the station',
    );
  });

  testWidgets('a ride that needs a train change says so before you start', (
    tester,
  ) async {
    await _pumpScreen(tester);

    await _pick(tester, 'Origin', 'Kalyan');
    await _pick(tester, 'Destination', 'Digha Gaon');

    expect(
      find.textContaining('Change at Thane onto Trans Harbour (platform 9, 10, or 10 A)'),
      findsOneWidget,
    );
  });

  testWidgets('a failed locate offers a retry on the chip, with a tip banner', (
    tester,
  ) async {
    await _pumpScreen(tester);

    // No location plugin exists under test, so the launch-time locate fails
    // the same way an indoor timeout does. The miss must not read as final:
    // the chip says so, and the banner teaches the tap at the exact moment
    // it matters.
    expect(
      find.textContaining('Tap to retry', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Tap the chip above'), findsOneWidget);

    // Tapping retries (and fails again here): the app must survive that and
    // keep offering the retry rather than crash or lie.
    await tester.tap(find.byKey(const Key('status_chip')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Tap to retry', findRichText: true),
      findsOneWidget,
    );

    // "Got it" waves the banner away for the session; the chip keeps the
    // retry affordance.
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tap the chip above'), findsNothing);
    expect(
      find.textContaining('Tap to retry', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets(
      'a screen born mid-ride shows the running ride, with no user action', (
    tester,
  ) async {
    // THE 15 JUL BUG, as a test. Android killed and recreated the activity
    // mid-ride, and the rebuilt screen came up with a blank destination and no
    // route while End journey was correctly offered: the widget's state died
    // with it and nothing re-read the ride. This pumps a screen that has NEVER
    // seen the ride start, exactly as a recreated process has not.
    //
    // Nothing below taps anything. That is the assertion.
    await _pumpScreen(
      tester,
      service: FakeRideServiceClient(
        running: true,
        originId: 'kalyan',
        destinationId: 'thane',
      ),
    );

    // The pickers show the ride the service is running.
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'Origin')).controller?.text,
      'Kalyan',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Destination'))
          .controller
          ?.text,
      'Thane',
    );

    // The route came back too, which is the half that was blank on 15 Jul.
    expect(find.textContaining('8 stations'), findsOneWidget);

    // And the screen knows a ride is live: End is offered, Start is not.
    expect(find.text('End journey'), findsOneWidget);
    expect(find.text('Start Travel Mode'), findsNothing);
  });

  testWidgets('a screen born with no ride running offers Start, not End', (
    tester,
  ) async {
    // The other half of the same contract: liveness is read from the store, so
    // it must be able to come back false as well as true. Without this the
    // recreation test above would pass against a provider hardcoded to "live".
    await _pumpScreen(tester, service: FakeRideServiceClient(running: false));

    expect(find.text('End journey'), findsNothing);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'Origin')).controller?.text,
      isEmpty,
    );
  });
}
