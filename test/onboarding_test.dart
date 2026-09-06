import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/screens/onboarding_screen.dart';
import 'package:commute_guardian/screens/travel_mode_screen.dart';
import 'package:commute_guardian/services/oem_guidance.dart';
import 'package:commute_guardian/state/readiness_providers.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_permissions.dart';
import 'support/fake_ride_service_client.dart';

/// Onboarding, six screens.
///
/// The rules under test are the ones that decide whether a stranger can use
/// this app at all: the disclosure comes BEFORE the system prompt (a Play
/// requirement, not a preference), refusing never traps anyone, and the
/// background-location screen exists because Android will not grant it from a
/// dialog.
void main() {
  _entryGateTests();

  Future<(FakePermissions, List<String>)> pump(
    WidgetTester tester, {
    bool android = true,
    OemGuidance guidance = const OemGuidance(
      family: OemFamily.none,
      brandLabel: '',
      steps: [],
    ),
  }) async {
    final permissions = FakePermissions(android: android);
    final done = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          permissionsGatewayProvider.overrideWithValue(permissions),
          oemGuidanceProvider.overrideWith((ref) async => guidance),
        ],
        child: MaterialApp(
          home: OnboardingScreen(onDone: () => done.add('done')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (permissions, done);
  }

  Future<void> act(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('onboarding_action')));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the promise, not on a permission request', (
    tester,
  ) async {
    final (permissions, _) = await pump(tester);

    expect(find.byKey(const Key('onboarding_welcome')), findsOneWidget);
    expect(find.text('Never miss your station'), findsOneWidget);
    // Nothing has been asked for yet. Asking on screen one is how apps get
    // refused, and on Play it is how they get rejected.
    expect(permissions.asked, isEmpty);
  });

  testWidgets('the disclosure comes BEFORE the system prompt', (tester) async {
    final (permissions, _) = await pump(tester);
    await act(tester); // leave welcome

    expect(find.byKey(const Key('onboarding_disclosure')), findsOneWidget);
    // Play requires all four: what, why, that it is background, and an
    // affirmative action.
    expect(find.textContaining('in the background'), findsOneWidget);
    expect(find.textContaining('announce each station'), findsOneWidget);
    expect(find.textContaining('never leaves your phone'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    // Still nothing asked: the disclosure is shown FIRST, then the prompt.
    expect(permissions.asked, isEmpty);

    await act(tester);
    expect(permissions.asked, ['whileInUse']);
  });

  testWidgets('background location gets its own screen, because Android '
      'will not grant it from a dialog', (tester) async {
    final (permissions, _) = await pump(tester);
    await act(tester); // welcome
    await act(tester); // disclosure, asks whileInUse

    expect(find.byKey(const Key('onboarding_background')), findsOneWidget);
    // The label the rider must hunt for is Android's wording, not ours.
    expect(find.text('Choose "Allow all the time"'), findsOneWidget);

    await act(tester);
    expect(permissions.asked, ['whileInUse', 'openSettings']);
  });

  testWidgets('refusing every step still reaches the end', (tester) async {
    final (permissions, done) = await pump(tester);
    await act(tester); // welcome has no skip

    // Refusing is a legitimate answer: the app degrades, it does not trap.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('onboarding_skip')));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);
    expect(permissions.asked, isEmpty);

    await act(tester);
    expect(done, ['done']);
  });

  testWidgets('every step advances, and the last one finishes', (tester) async {
    final (permissions, done) = await pump(tester);
    for (var i = 0; i < 6; i++) {
      await act(tester);
    }

    expect(done, ['done']);
    expect(permissions.asked, ['whileInUse', 'openSettings', 'notifications']);
  });

  testWidgets('no step overflows a real phone screen', (tester) async {
    // The 3T's own resolution at its device pixel ratio. A fixed spacer put
    // the disclosure 81 pixels off the bottom here and took the skip button
    // with it, which no test at the default 800x600 surface noticed.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final (_, _) = await pump(tester);
    for (var step = 0; step < 6; step++) {
      // An overflow paints an error and, in a test, throws. Reaching the end
      // of the loop IS the assertion.
      expect(tester.takeException(), isNull, reason: 'step $step overflowed');
      if (step < 5) {
        // Scroll it into reach first. The disclosure is taller than this
        // screen by design, and tapping at a coordinate the button is not at
        // would make this test pass without proving anything.
        final action = find.byKey(const Key('onboarding_action'));
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
      }
    }
  });

  group('THE SECOND BATTERY LIST, BEFORE THE FIRST RIDE', () {
    // 5 SEP 2026. A tester's Xiaomi ran the first ride with
    // ignoringBatteryOptimizations=false and it stopped after 5m32s. The owner
    // fixed it by hand from the phone's own settings, mid-platform, because
    // nothing in the app had ever mentioned it.
    //
    // The guidance screen has existed since 26 Aug and is reachable from
    // Settings. That is the wrong place: a rider meets this AFTER their first
    // ride dies, and a ride lost to an OEM killer looks exactly like a bug in
    // the geofence chain. So the phones that need it are told during
    // onboarding, before there is anything to lose.
    //
    // It is INSTRUCTIONS, never a status. The autostart list has no API, so
    // nothing here can be verified and nothing here may claim to be.

    const xiaomi = OemGuidance(
      family: OemFamily.xiaomi,
      brandLabel: 'Xiaomi',
      steps: ['Open Settings', 'Turn on Autostart'],
    );

    testWidgets('a phone with a second list is told, by name', (tester) async {
      final (_, _) = await pump(tester, guidance: xiaomi);
      await act(tester); // welcome
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('onboarding_skip')));
        await tester.pumpAndSettle();
      }

      expect(
        find.byKey(const Key('onboarding_oem')),
        findsOneWidget,
        reason: 'a Xiaomi keeps a list the app cannot reach',
      );
      expect(
        find.textContaining('Xiaomi'),
        findsWidgets,
        reason: 'the name on the back of the phone, not a generic warning',
      );
    });

    testWidgets('and it comes BEFORE the ride, not after it', (tester) async {
      final (_, _) = await pump(tester, guidance: xiaomi);
      await act(tester);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('onboarding_skip')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('onboarding_ready')), findsNothing);

      await tester.tap(find.byKey(const Key('onboarding_skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);
    });

    testWidgets('a phone with no second list is never shown one', (
      tester,
    ) async {
      // A Pixel has nothing to do here, and a warning about a setting that
      // does not exist on this phone teaches the rider to distrust the rest.
      final (_, done) = await pump(tester);
      await act(tester);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('onboarding_skip')));
        await tester.pumpAndSettle();
      }

      expect(find.byKey(const Key('onboarding_oem')), findsNothing);
      expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);
      await act(tester);
      expect(done, ['done']);
    });

    testWidgets('refusing it still reaches the end, like every other step', (
      tester,
    ) async {
      final (_, done) = await pump(tester, guidance: xiaomi);
      await act(tester);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('onboarding_skip')));
        await tester.pumpAndSettle();
      }
      await act(tester);
      expect(done, ['done'], reason: 'refusing never traps anyone');
    });
  });

  testWidgets('iOS skips the battery screen rather than promising nothing', (
    tester,
  ) async {
    final (_, done) = await pump(tester, android: false);
    await act(tester); // welcome
    await act(tester); // disclosure
    await act(tester); // background
    await act(tester); // notifications

    // Step 4 is Android-only, so iOS lands straight on the last screen.
    expect(find.byKey(const Key('onboarding_battery')), findsNothing);
    expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);

    await act(tester);
    expect(done, ['done']);
  });
}

/// The entry gate. What a rider sees when they open the app, which is the
/// whole point of having built onboarding.
void _entryGateTests() {
  Future<AppDatabase> pumpApp(
    WidgetTester tester, {
    required bool seen,
    FakeRideServiceClient? service,
  }) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    if (seen) await db.markOnboardingSeen();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          permissionsGatewayProvider.overrideWithValue(FakePermissions()),
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(
              File(StationRepository.assetPath).readAsStringSync(),
            ),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
          rideServiceClientProvider.overrideWithValue(
            service ?? FakeRideServiceClient(),
          ),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  testWidgets(
    'REOPENING MID-RIDE LANDS ON THE RIDE, not on Home (the 11 Aug recents '
    'swipe)',
    (tester) async {
      // Reported on device 11 Aug 2026, Android: swiping the app out of recents
      // leaves the foreground service running correctly (the 30 Jul swipe bench
      // proved that), but reopening the app landed on Home. The chain, the next
      // station and End journey were all unreachable on a ride that was still
      // running.
      //
      // The cause was narrow: showTravelMode() had two callers and both of them
      // START a ride. Restoring the pickers was the 15 Jul fix and was never the
      // whole job.
      //
      // Nothing below taps anything, which is the assertion.
      await pumpApp(
        tester,
        seen: true,
        service: FakeRideServiceClient(
          running: true,
          originId: 'kalyan',
          destinationId: 'thane',
        ),
      );

      expect(find.byType(TravelModeScreen), findsOneWidget);
    },
  );

  testWidgets('reopening with no ride running still lands on Home', (
    tester,
  ) async {
    // The other half, and the one that would fail if the restore ever pushed
    // Screen 4 unconditionally.
    await pumpApp(tester, seen: true);
    expect(find.byType(TravelModeScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a first-time rider lands in onboarding, not the app', (
    tester,
  ) async {
    await pumpApp(tester, seen: false);
    expect(find.byKey(const Key('onboarding_welcome')), findsOneWidget);
  });

  testWidgets(
    'a rider who has done it lands on Screen 1, not the debug screen',
    (tester) async {
      await pumpApp(tester, seen: true);
      expect(find.byKey(const Key('onboarding_welcome')), findsNothing);

      // THE PHASE 2 EXIT CRITERION, as an assertion: a rider who has never seen
      // the debug screen must not be shown it. It was the app's home until
      // 4 Aug 2026, and nothing but this test stops it quietly becoming the home
      // again the next time someone needs a bench in a hurry.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(RideDebugScreen), findsNothing);
    },
  );

  testWidgets('finishing onboarding records it and does not ask again', (
    tester,
  ) async {
    final db = await pumpApp(tester, seen: false);
    expect(await db.hasSeenOnboarding(), isFalse);

    // Walk the whole flow: welcome, then skip the four permission screens,
    // then the ready screen's action.
    await tester.tap(find.byKey(const Key('onboarding_action')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('onboarding_skip')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('onboarding_action')));
    await tester.pumpAndSettle();

    // The flag is written, and the gate has already moved on without a
    // restart.
    expect(await db.hasSeenOnboarding(), isTrue);
    expect(find.byKey(const Key('onboarding_ready')), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
