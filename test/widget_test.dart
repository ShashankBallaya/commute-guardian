import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/arrival_screen.dart';
import 'package:commute_guardian/screens/ride_orchestration.dart';
import 'package:commute_guardian/screens/wake_alert_screen.dart';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/theme/app_theme.dart';
import 'package:commute_guardian/widgets/slide_to_start.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';

import 'support/fake_ride_service_client.dart';

/// Brings the screen up with the real station network loaded.
///
/// The repository is read straight off disk rather than through `rootBundle`,
/// because the asset bundle does real I/O and real I/O cannot make progress
/// inside the fake-async zone that `pump` runs in: the pickers would come up
/// empty and disabled, and the whole screen would be untestable.
final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> _pumpScreen(
  WidgetTester tester, {
  AppDatabase? history,
  FakeRideServiceClient? service,
  bool underRoot = false,
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
      // The DEBUG SCREEN directly, not the app, since 4 Aug 2026. These tests
      // are about the screen, and mounting the app to reach it meant the entry
      // gate decided what they examined: flipping the gate to Screen 1 failed
      // eleven tests that had no opinion about the gate at all. The theme is
      // the app's real one, so anything judged on colour still is.
      child: MaterialApp(
        theme: commuteGuardianTheme(),
        navigatorKey: _navigatorKey,
        // underRoot mounts the screen OVER another route, so a test can tell
        // the difference between closing one route and closing two.
        home: underRoot
            ? const Scaffold(body: Center(child: Text('beneath')))
            : const RideDebugScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (underRoot) {
    unawaited(
      _navigatorKey.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const RideDebugScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

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
  // The alert latches are static so two hosts cannot both open one alert, which
  // means they survive between tests in this process the way they survive
  // between screens in the app. Each test is a new ride.
  setUp(RideOrchestration.resetAlertLatches);

  testWidgets('the ride cannot be started until one has been picked', (
    tester,
  ) async {
    await _pumpScreen(tester);

    expect(find.text('Pick an origin and a destination.'), findsOneWidget);

    // Starting the service with no journey would run a ride nobody chose. The
    // track stays dead until JourneyPlanner has actually planned one, and a
    // dead track does not move at all: a slider that travels and then snaps
    // back says "broken" where a still one says "not yet".
    final start = tester.widget<SlideToStart>(find.byType(SlideToStart));
    expect(start.enabled, isFalse);
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

    final start = tester.widget<SlideToStart>(find.byType(SlideToStart));
    expect(start.enabled, isTrue);
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

  testWidgets('arriving opens Screen 5, before any countdown exists', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);
    expect(find.byType(ArrivalScreen), findsNothing);

    // The arrival, which is what the announcement commits to. Screen 5 must
    // NOT wait for the wind-down countdown: WindDown only starts counting after
    // two walking-speed fixes 150 m from where the train stopped, about six
    // minutes after the doors opened on the 18 Jul Kalyan log. Waiting would
    // hide this screen for the entire walk down the platform.
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();

    expect(find.byType(ArrivalScreen), findsOneWidget);
    // The no-countdown state: End now is offered, Extend is not, because there
    // is nothing yet to extend.
    expect(find.text('Extend 10 min'), findsNothing);

    // NAMES THE DESTINATION. An earlier draft named journey.chain[reachedIndex]
    // instead, and the debug bench (which fires an arrival without moving
    // progress) put "You've arrived at Kalyan" on a ride to Thane.
    expect(find.textContaining('Thane'), findsWidgets);
    expect(find.textContaining("You've arrived at Kalyan"), findsNothing);
  });

  testWidgets('End now closes Screen 5 and nothing underneath it', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    // THE HOST IS PUSHED OVER SOMETHING, which is the whole point of this test
    // and the reason the first version of it was worthless: mounted as the root
    // route, a stray second pop has nothing to take and the bug cannot show. On
    // the device the host really is pushed (Settings, then the debug screen).
    await _pumpScreen(tester, service: service, underRoot: true);
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();
    expect(find.byType(ArrivalScreen), findsOneWidget);

    // Ending clears the ride, and the liveness watcher pops this route. Popping
    // in the button's own callback AS WELL took the route underneath with it:
    // on the device that surfaced as End now landing on Settings, two screens
    // back. Invisible on the product path, where both pops happen to end up
    // somewhere sensible.
    service.running = false;
    await tester.tap(find.text('End now'));
    service.emit(const RideEndedByService());
    await tester.pumpAndSettle();

    expect(find.byType(ArrivalScreen), findsNothing);
    expect(find.byType(RideDebugScreen), findsOneWidget,
        reason: 'the host must survive its arrival screen closing');
  });

  testWidgets('an arrival opens exactly one Screen 5, however many fixes land',
      (tester) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);

    // A service can repeat itself across a reconnect, and the store seeds the
    // same truth the stream announces. Two arrival screens stacked on each
    // other would leave a rider tapping End now twice.
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();

    expect(find.byType(ArrivalScreen), findsOneWidget);
  });

  testWidgets('a screen born mid-alarm can still answer the alarm', (
    tester,
  ) async {
    // THE 30 JUL SWIPE BENCH, as a test. The app was swiped out of recents
    // while the wake ladder was climbing. The service is never killed by that,
    // so the alarm kept sounding, but every ack died with the UI: the media
    // session was released, the notification carried no button, and reopening
    // the app did NOT bring "I'm awake" back. The old comment on RideAlerts
    // predicted the button would return "until the next rung's event arrives",
    // and that was wrong, because rungs do not re-announce liveness.
    //
    // So this pumps a screen that never saw the ladder start, and asserts it
    // finds out anyway. Nothing below taps anything.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
      wakeLadderLive: true,
    );
    await _pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    // The ack the rider can see.
    expect(find.text("I'm awake"), findsOneWidget);

    // And the ack they cannot see, which is the one that matters with the
    // phone in a pocket: the earphone tap has to route to us again.
    expect(service.commands, contains('setMediaSession:true'));
  });

  testWidgets('a quiet ride does not claim the rider\'s media buttons', (
    tester,
  ) async {
    // The other half of the seed. Outside a live ladder the earphone tap must
    // keep controlling the rider's music, so a screen born mid-ride with
    // nothing sounding must not grab the session on the way up.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    expect(find.text("I'm awake"), findsNothing);
    expect(service.commands, isNot(contains('setMediaSession:true')));
  });

  testWidgets('a ride whose UI died still gets its history row', (
    tester,
  ) async {
    // SWIPING THE APP OUT OF RECENTS DOES NOT STOP THE RIDE. The foreground
    // service restarts itself about a second later (no stopWithTask flag, so
    // ForegroundService.onTaskRemoved sets a restart alarm), and the journey
    // carries on watching for the stop. Until 29 Jul the history row was three
    // widget fields, so the ride survived and its RECORD did not: the rider
    // was woken correctly and the journey then never appeared in History.
    //
    // This pumps a screen that never saw the ride start, exactly as a recreated
    // process has not, and ends the ride from there.
    final startedAt = DateTime(2026, 7, 29, 18, 30);
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
      startedAt: startedAt,
      startBatteryPct: 82,
    );
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await _pumpScreen(tester, service: service, history: db);

    // Hold, not tap: End journey is hold-to-confirm here too.
    await tester.longPress(find.text('End journey'));
    // Past the battery read's 2 s timeout: battery_plus never answers under the
    // test binding, and the record waits on it.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    final rides = await db.recent();
    expect(rides, hasLength(1), reason: 'the journey must be recorded');
    expect(rides.single.originName, 'Kalyan');
    expect(rides.single.destinationName, 'Thane');
    expect(rides.single.startedAt, startedAt);
    expect(rides.single.batteryStartPct, 82);
    expect(
      rides.single.stationCount,
      greaterThan(1),
      reason: 'replanned from the ids the service was handed',
    );
    // The seed is cleared so a later teardown cannot write the ride twice.
    expect(service.commands, contains('clearRideRecordSeed'));
  });

  testWidgets('a climbing ladder opens the wake alert and updates its rung', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);
    expect(find.byType(WakeAlertScreen), findsNothing);

    service.emit(const WakeLadderChanged(true, rung: 1));
    await tester.pumpAndSettle();
    expect(find.byType(WakeAlertScreen), findsOneWidget);
    expect(
      tester.widget<WakeAlertScreen>(find.byType(WakeAlertScreen)).rung,
      1,
    );

    // THE RUNG MOVES WITHOUT LIVENESS MOVING. The glow steps with the sound, so
    // a ladder climbing 1 to 3 has to reach the screen; keyed on liveness alone
    // it would hold the quietest glow through the loudest alarm.
    service.emit(const WakeLadderChanged(true, rung: 3, climbing: false));
    await tester.pumpAndSettle();
    final screen =
        tester.widget<WakeAlertScreen>(find.byType(WakeAlertScreen));
    expect(screen.rung, 3);
    expect(screen.climbing, isFalse);
  });

  testWidgets('the wake alert leaves when the ladder is answered anywhere', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);

    service.emit(const WakeLadderChanged(true, rung: 1));
    await tester.pumpAndSettle();
    expect(find.byType(WakeAlertScreen), findsOneWidget);

    // Answered by an EARPHONE TAP, not by this screen's button. The ack belongs
    // to the service (24 Jul bench), so the screen has to leave on liveness
    // rather than on its own press, or a rider who taps their earphones is left
    // staring at an alarm screen for an alarm that has stopped.
    service.emit(const WakeLadderChanged(false));
    await tester.pumpAndSettle();
    expect(find.byType(WakeAlertScreen), findsNothing);
  });

  testWidgets('arrival opens Screen 5 even with another route on top', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service, underRoot: true);

    // THE RIDE CASE, and the one an earlier draft got wrong. On a real ride the
    // rider is on Screen 4, pushed OVER the host, so the host's route is not
    // current. Guarding on isCurrent meant Screen 5 would never have opened on
    // the ride at all, and the bench missed it because the debug screen fired
    // the arrival while its own route was on top.
    unawaited(
      _navigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Center(child: Text('on top'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('on top'), findsOneWidget);

    service.emit(const DestinationReached());
    await tester.pumpAndSettle();
    expect(find.byType(ArrivalScreen), findsOneWidget);
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
