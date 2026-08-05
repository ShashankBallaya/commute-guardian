import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/screens/onboarding_screen.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/services/permissions_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

/// Onboarding, six screens.
///
/// The rules under test are the ones that decide whether a stranger can use
/// this app at all: the disclosure comes BEFORE the system prompt (a Play
/// requirement, not a preference), refusing never traps anyone, and the
/// background-location screen exists because Android will not grant it from a
/// dialog.
class _FakePermissions implements PermissionsGateway {
  _FakePermissions({this.android = true});

  final bool android;
  final List<String> asked = [];
  bool whileInUseGranted = true;

  @override
  bool get isAndroid => android;

  @override
  Future<bool> requestWhileInUse() async {
    asked.add('whileInUse');
    return whileInUseGranted;
  }

  @override
  Future<bool> requestAlways() async {
    asked.add('always');
    return false;
  }

  @override
  Future<bool> requestNotifications() async {
    asked.add('notifications');
    return true;
  }

  @override
  Future<bool> openSettings() async {
    asked.add('openSettings');
    return true;
  }

  @override
  Future<bool> hasWhileInUse() async => whileInUseGranted;
  @override
  Future<bool> hasAlways() async => false;
  @override
  Future<bool> hasNotifications() async => true;
}

void main() {
  _entryGateTests();

  Future<(_FakePermissions, List<String>)> pump(
    WidgetTester tester, {
    bool android = true,
  }) async {
    final permissions = _FakePermissions(android: android);
    final done = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [permissionsGatewayProvider.overrideWithValue(permissions)],
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
  Future<AppDatabase> pumpApp(WidgetTester tester, {required bool seen}) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    if (seen) await db.markOnboardingSeen();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          permissionsGatewayProvider.overrideWithValue(_FakePermissions()),
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(
              File(StationRepository.assetPath).readAsStringSync(),
            ),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
          rideServiceClientProvider.overrideWithValue(FakeRideServiceClient()),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

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
