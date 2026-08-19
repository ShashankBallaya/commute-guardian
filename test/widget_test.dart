import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/arrival_screen.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/screens/ride_orchestration.dart';
import 'package:commute_guardian/screens/wake_alert_screen.dart';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/theme/app_theme.dart';
import 'package:commute_guardian/widgets/primary_button.dart';
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
        stationRepositoryProvider.overrideWith(
          (ref) async => StationRepository.parse(raw),
        ),
        // Fails like an indoor timeout does. The real plugin cannot answer in
        // the fake-async zone; without this the chip hangs on "Locating...".
        fixAcquirerProvider.overrideWithValue(
          () async => throw StateError('no GPS under test'),
        ),
        // No isolate under test, so no plugin channels either.
        rideServiceClientProvider.overrideWithValue(
          service ?? FakeRideServiceClient(),
        ),
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

/// The phone goes in a pocket and comes back out.
///
/// THE FULL LEGAL SEQUENCE, not a jump to resumed. `AppLifecycleListener`
/// asserts on an illegal transition, so a shortcut here throws instead of
/// testing anything: going straight from inactive to paused is rejected, and
/// the resume callback never fires. Real platforms send every step.
Future<void> _pocketAndReturn(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
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

    // Starting the service with no journey would run a ride nobody chose, so
    // the button is present and INERT rather than absent: a control that
    // appears out of nowhere reads as the app changing its mind.
    final start = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
    expect(start.enabled, isFalse);
  });

  testWidgets('THE DEBUG SCREEN GREETS THE WAY A PRODUCT START GREETS', (
    tester,
  ) async {
    await _pumpScreen(tester);

    // It defaulted to OFF while this was a bench flag and every product Start
    // was hardcoded false: the switch was the only way to hear the clip. Once
    // the product Start asked for the greeting (19 Aug 2026), that default
    // made this screen the ONE place in the app that does not do what a rider
    // gets, and every bench in this project runs through this screen.
    final greetingSwitch = tester.widget<Switch>(
      find.byKey(const Key('sarvam_greeting_switch')),
    );
    expect(greetingSwitch.value, isTrue);
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

    final start = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
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
      find.textContaining(
        'Change at Thane onto Trans Harbour (platform 9, 10, or 10 A)',
      ),
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
    'a screen born mid-ride shows the running ride, with no user action',
    (tester) async {
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
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Origin'))
            .controller
            ?.text,
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
    },
  );

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

  testWidgets('A TAP THAT CANNOT BECOME A RIDE SAYS SO, on every path in', (
    tester,
  ) async {
    // JourneyPlanner refuses origin == destination, so plannedJourneyProvider
    // holds an error and start() returns on a null journey: the rider tapped
    // and NOTHING happened. A saved Home is a station someone stands at twice a
    // day, so this is the ordinary case, not an exotic one.
    //
    // Through the WHOLE APP rather than the picker, because the picker is one
    // of three ways in and the cards on Screen 1 are the other two.
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await db.record(
      originId: 'thane',
      destinationId: 'shahad',
      originName: 'Thane',
      destinationName: 'Shahad',
      startedAt: DateTime(2026, 8, 5, 9),
      endedAt: DateTime(2026, 8, 5, 10),
      reachedDestination: true,
      stationCount: 9,
    );
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'shahad',
      destinationName: 'Shahad',
    );
    final service = FakeRideServiceClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          onboardingSeenProvider.overrideWith((ref) async => true),
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(
              File(StationRepository.assetPath).readAsStringSync(),
            ),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
          rideServiceClientProvider.overrideWithValue(service),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The rider is standing at the station they saved as Home.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    container.read(journeyDraftProvider.notifier).setOrigin('shahad');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('saved_route_card_home')));
    await tester.pumpAndSettle();

    expect(find.text("You're already at Shahad."), findsOneWidget);
    expect(
      service.commands.where((c) => c.startsWith('startRide')),
      isEmpty,
      reason: 'a ride nobody can take must not be started',
    );
  });

  testWidgets('A RIDER CARRIED PAST THEIR STOP IS TOLD WHERE THEY ARE', (
    tester,
  ) async {
    // The 4 Aug open item, and the one tomorrow's ride is built to provoke:
    // Ghatkopar to Shahad carries an Ambivli overshoot pin. WindDown has moved
    // its exit watch to the pin since 22 Jul, so the app already knew; the fact
    // just never crossed the isolate boundary, and Screen 5 went on naming the
    // destination.
    //
    // THE PIN IS REACHED AFTER THE ARRIVAL, so this screen is already open and
    // already wrong when the correction lands. That is why the name is watched
    // rather than read once before the push.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'ghatkopar',
      destinationId: 'shahad',
    );
    await _pumpScreen(tester, service: service);

    service.emit(const DestinationReached());
    await tester.pumpAndSettle();
    expect(find.textContaining("You've arrived at Shahad"), findsOneWidget);

    // Carried past. The train rolls on and the app tells them to get off at the
    // next station instead.
    service.emit(const AlightingAt('ambivli'));
    await tester.pumpAndSettle();

    expect(find.textContaining("You've arrived at Ambivli"), findsOneWidget);
    expect(find.textContaining("You've arrived at Shahad"), findsNothing);
    // The journey summary still describes the JOURNEY, which was to Shahad.
    // Only the platform under the rider's feet changed.
    expect(find.textContaining('→ Shahad'), findsOneWidget);
  });

  testWidgets('a screen born after the pin still names the right platform', (
    tester,
  ) async {
    // Sent AND saved. A process recreated between the overshoot and the rider
    // looking at their phone reads the store, and the store has to agree.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'ghatkopar',
      destinationId: 'shahad',
      alightStationId: 'ambivli',
    );
    await _pumpScreen(tester, service: service);

    service.emit(const DestinationReached());
    await tester.pumpAndSettle();

    expect(find.textContaining("You've arrived at Ambivli"), findsOneWidget);
  });

  testWidgets('saving at journey end writes the route the service rode', (
    tester,
  ) async {
    // The whole path, end to end: arrive, name it, and it is on disk. The
    // destination comes from the LIVE ride rather than the draft, the same rule
    // recordRide follows, because the picker can replan mid-ride while the
    // service keeps riding the chain it was handed.
    final db = AppDatabase.inMemory();
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service, history: db);
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();

    // Screen 1 is underneath, holding this query open, so the same staleness
    // that hid a finished ride from Recents would hide the saved route from
    // the cards it exists to fill.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ArrivalScreen)),
    );
    final sub = container.listen(savedRoutesProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(savedRoutesProvider.future), isEmpty);

    await tester.tap(find.byKey(const Key('save_route_home')));
    await tester.pumpAndSettle();

    expect(
      (await container.read(savedRoutesProvider.future)).map((r) => r.label),
      ['Home'],
    );

    final saved = await db.allSavedRoutes();
    expect(saved, hasLength(1));
    expect(saved.single.label, 'Home');
    expect(saved.single.destinationStationId, 'thane');
    expect(saved.single.destinationName, 'Thane');
  });

  testWidgets('a destination already saved is not asked about again', (
    tester,
  ) async {
    // The read happens BEFORE the screen is pushed, which is exactly the kind
    // of await that gets dropped in a refactor. Without it the rider is asked
    // to save a route they saved last week, every single time they ride it.
    final db = AppDatabase.inMemory();
    await db.saveRoute(
      label: 'Work',
      destinationStationId: 'thane',
      destinationName: 'Thane',
    );
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service, history: db);
    service.emit(const DestinationReached());
    await tester.pumpAndSettle();

    expect(find.byType(ArrivalScreen), findsOneWidget);
    expect(find.text('Save this route?'), findsNothing);
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
    expect(
      find.byType(RideDebugScreen),
      findsOneWidget,
      reason: 'the host must survive its arrival screen closing',
    );
  });

  testWidgets(
    'an arrival opens exactly one Screen 5, however many fixes land',
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
    },
  );

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

  testWidgets('THE RIDE JUST FINISHED IS ON SCREEN 1 WITHOUT A RESTART', (
    tester,
  ) async {
    // Screen 1 sits UNDERNEATH the ride and is never disposed while it runs, so
    // its autoDispose query keeps the answer it read before the ride started.
    // The destination the rider just rode to was therefore missing from Recents
    // until the app was killed: the card they would have tapped next was the
    // one that was not there.
    //
    // The listener is what makes this test able to fail. A bare read of an
    // autoDispose provider rebuilds it every time and is always fresh; holding
    // a subscription open is what a mounted Screen 1 does.
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
      startedAt: DateTime(2026, 8, 5, 18, 30),
    );
    await _pumpScreen(tester, service: service, history: db);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(RideDebugScreen)),
    );
    final sub = container.listen(recentDestinationsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(recentDestinationsProvider.future), isEmpty);

    await tester.longPress(find.text('End journey'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    final recents = await container.read(recentDestinationsProvider.future);
    expect(recents.map((r) => r.destinationName), ['Thane']);
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
    final screen = tester.widget<WakeAlertScreen>(find.byType(WakeAlertScreen));
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
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Origin'))
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('AN ALARM ANSWERED WHILE THE APP SLEPT LETS THE RIDER OUT', (
    tester,
  ) async {
    // THE 9 AUG 2026 RIDE, as a test, and it is the worst failure this app has
    // shipped. The rider acked the ladder with an earphone tap at 20:52:54 with
    // the phone in his pocket. The service stood the ladder down and said so;
    // the suspended UI isolate never received it, because sendDataToMain has no
    // queue and nothing re-read the store on the way back in. The alert screen
    // leaves on liveness going false, so it never left. He pressed "I'm awake"
    // SIXTY-SIX times against a service that had no ladder to stand down, and
    // force-stopped the app.
    //
    // Everything below happens with NO event emitted, on purpose. The event is
    // exactly what a pocketed phone does not get.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);

    // The ladder starts while the rider is still looking at the phone, which is
    // what happened at 20:52:21: the screen went up and he saw it.
    service.emit(const WakeLadderChanged(true, rung: 1));
    service.wakeLadderLive = true;
    await tester.pumpAndSettle();
    expect(find.byType(WakeAlertScreen), findsOneWidget);

    // The ack the rider actually used, reaching the service while the UI is
    // away: the store flips, and nothing tells the screen.
    service.wakeLadderLive = false;
    await tester.pump();
    expect(
      find.byType(WakeAlertScreen),
      findsOneWidget,
      reason: 'nothing has told the UI yet, so the screen is still up',
    );

    // He takes the phone out of his pocket.
    await _pocketAndReturn(tester);

    expect(
      find.byType(WakeAlertScreen),
      findsNothing,
      reason: 'resume must re-read the store and let the rider out',
    );
  });

  testWidgets('an arrival announced while the app slept still opens Screen 5', (
    tester,
  ) async {
    // The second symptom of the same cause, and the owner reported it on BOTH
    // phones: "I didn't see the wind-down screen on both of the phones".
    // destinationReached is sent AND saved by the service, but the watcher only
    // ever listened to the live stream.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);
    await tester.pumpAndSettle();
    expect(find.byType(ArrivalScreen), findsNothing);

    // Arrived while the phone was in a pocket. No event.
    service.destinationReached = true;
    await tester.pump();
    expect(find.byType(ArrivalScreen), findsNothing);

    await _pocketAndReturn(tester);

    expect(find.byType(ArrivalScreen), findsOneWidget);
  });

  testWidgets('a resume does not invent an alarm that is not sounding', (
    tester,
  ) async {
    // The other direction, and the reason resync reads the store rather than
    // ORing it: a quiet ride must stay quiet across a resume, and the earphone
    // buttons must stay with the rider's music.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'kalyan',
      destinationId: 'thane',
    );
    await _pumpScreen(tester, service: service);
    await tester.pumpAndSettle();

    await _pocketAndReturn(tester);

    expect(find.byType(WakeAlertScreen), findsNothing);
    expect(service.commands, isNot(contains('setMediaSession:true')));
  });

  testWidgets('RESUMING A KILLED RIDE PUTS THE RIDER BACK ON SCREEN 4', (
    tester,
  ) async {
    // THE WHOLE FEATURE, END TO END, on the product host. The 16 Aug exit ride
    // was jetsammed by iOS mid-journey and nothing anywhere noticed.
    //
    // The half this test exists for is the LAST one, and it is the half that
    // was missing when the logic was first written: a service is not a screen.
    // Starting the ride and leaving the rider on Home would give them no chain,
    // no next station and no End journey, on a ride that is running, which is
    // the same complaint the 11 Aug swipe produced.
    final service = FakeRideServiceClient(
      running: false,
      rideInFlight: true,
      originId: 'shahad',
      destinationId: 'thane',
      startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
    );
    // The resume path asks for permissions like every start does, and
    // permission_handler's channel has no implementation under this binding.
    // Answering "granted" is the state a rider who has ridden before is in.
    _grantPermissions(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(
              File(StationRepository.assetPath).readAsStringSync(),
            ),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
          appDatabaseProvider.overrideWith((ref) {
            final db = AppDatabase.inMemory();
            ref.onDispose(db.close);
            return db;
          }),
          onboardingSeenProvider.overrideWith((ref) async => true),
          rideServiceClientProvider.overrideWithValue(service),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The offer is on Home, and no ride is running yet.
    expect(find.byKey(const Key('resume_ride_card')), findsOneWidget);
    expect(find.text('Still going to Thane?'), findsOneWidget);
    expect(service.running, isFalse);

    await tester.tap(find.byKey(const Key('resume_ride_card')));
    await tester.pumpAndSettle();

    // The ORIGINAL journey was restarted, not a new one planned from wherever
    // the rider is standing now. That replan is the 9 Aug stale-origin bug.
    expect(service.commands, contains('startRide:shahad->thane'));
    expect(service.running, isTrue);

    // THE APP GREETS THE RIDER IN ITS OWN VOICE. False for every product Start
    // until 19 Aug 2026, which meant the bundled greeting clip had only ever
    // been heard from the debug screen. Asserted on a real Start rather than
    // by reading the source, because what matters is that the flag crosses
    // into the service isolate, which is where the pulse interval was once
    // silently dropped.
    expect(service.sarvamGreetingPassed, isTrue);

    // AND THE RIDER IS ON THE RIDE. Screen 4, with the ride's own controls.
    expect(find.text('End journey'), findsOneWidget);
    // The offer is gone, because a ride is running rather than because
    // anything cleared the flag underneath it.
    expect(find.byKey(const Key('resume_ride_card')), findsNothing);
    expect(service.commands, isNot(contains('clearRideInFlight')));
  });
}

/// Answers permission_handler's channel as a phone whose rider has already
/// granted everything. Without it the resume path throws on a channel that has
/// no implementation under the test binding.
void _grantPermissions(WidgetTester tester) {
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    switch (call.method) {
      case 'requestPermissions':
        // PermissionStatus.granted is 1. The argument is the list of
        // permission ints being asked for.
        return {for (final p in call.arguments as List) p as int: 1};
      case 'checkPermissionStatus':
        return 1;
      case 'checkServiceStatus':
        return 1;
      default:
        return null;
    }
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}
