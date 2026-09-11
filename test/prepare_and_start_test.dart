import 'dart:async';
import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/screens/onboarding_screen.dart'
    show permissionsGatewayProvider;
import 'package:commute_guardian/screens/preparing_flow.dart';
import 'package:commute_guardian/screens/route_picker_sheet.dart';
import 'package:commute_guardian/services/audio_output_gateway.dart';
import 'package:commute_guardian/services/commit_announcer.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/screens/ride_orchestration.dart'
    show rideDidNotStartMessage;
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/state/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_permissions.dart';
import 'support/fake_ride_service_client.dart';

/// `prepareAndStart`, driven from a tap on Screen 1 to a running ride.
///
/// THE ONE DOOR INTO EVERY RIDE A RIDER STARTS, and until 11 Sep 2026 no test
/// walked through it. Screen 1's saved, recent and suggested cards and Screen
/// 2's picker all end in `unawaited(prepareAndStart(id))`, so anything that
/// throws or hangs inside it goes NOWHERE: no ride, no screen, no log. On a
/// phone that is a dead tap, and a rider who meets a dead tap decides the app
/// is broken.
///
/// Each piece had its own suite (the gate's report, the flow's stages, the
/// picker, the service fake), and the chain joining them had none. The probe
/// that opened this file measured why: under the test binding the earphone
/// probe and the commit window's voice only settle in REAL time, so a widget
/// test tapping Screen 1 saw nothing happen and could not tell a hang from a
/// harness that was simply too fast. The seams are
/// `permissionsGatewayProvider`, `audioOutputGatewayProvider` and
/// `commitAnnouncerProvider`, and every test below runs in fake time.
void main() {
  late StationRepository repo;

  setUpAll(() {
    repo = StationRepository.parse(
      File(StationRepository.assetPath).readAsStringSync(),
    );
  });

  testWidgets('A TAP ON SCREEN 1 BECOMES A RIDE, through every step between', (
    tester,
  ) async {
    final harness = await _Harness.pump(tester);
    await harness.standAt(repo, 'kalyan');

    harness.tapDestination('dombivli');
    await harness.runUntilRiding();

    expect(harness.service.commands, contains('startRide:kalyan->dombivli'));
    expect(
      harness.announcer.lines.single,
      contains('Dombivli'),
      reason: 'the commit window spoke the route before the ride began',
    );
    expect(find.text('End journey'), findsOneWidget, reason: 'on Screen 4');
  });

  testWidgets('THE CORRIDOR SHE PICKS IS THE ONE THE SERVICE IS HANDED', (
    tester,
  ) async {
    // Link 2 of the C7c loop (sheet -> draft -> service store -> resumed
    // ride), which until today was a SOURCE guard in route_picker_test.dart
    // because nothing could drive this path. Asserted on the value that
    // crossed into the fake service, not on a line of code.
    final options = repo.planner.planAlternatives(
      originId: 'ghansoli',
      destinationId: 'csmt',
    );
    expect(options.length, greaterThan(1), reason: 'or this tests nothing');
    final other = options[1];

    final harness = await _Harness.pump(tester);
    await harness.standAt(repo, 'ghansoli');

    harness.tapDestination('csmt');
    await harness.runUntil(
      () => find.byType(RoutePickerSheet).evaluate().isNotEmpty,
    );
    // The sheet EXISTS a frame before it has risen, and a tap on a card still
    // sliding up from below the screen lands on nothing.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text(other.viaLabel ?? 'Direct, no change'));
    await harness.runUntilRiding();

    expect(harness.service.commands, contains('startRide:ghansoli->csmt'));
    expect(harness.service.routeChainPassed, other.chainIds);
  });

  group('a probe that fails must not eat the tap', () {
    testWidgets('A PERMISSION READ THAT THROWS still reaches a ride', (
      tester,
    ) async {
      // permission_handler answers through a platform channel, and a channel
      // can throw. `hasAlways` had no catch, so the throw left the gate,
      // left prepareAndStart, and vanished into the unawaited call.
      final harness = await _Harness.pump(
        tester,
        permissions: _ThrowingPermissions(),
      );
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntilRiding();

      expect(harness.service.commands, contains('startRide:kalyan->dombivli'));
    });

    testWidgets('AN EARPHONE PROBE THAT NEVER ANSWERS still reaches a ride', (
      tester,
    ) async {
      // `earphonesConnected` bounded `getDevices` at two seconds but not the
      // `AudioSession.instance` await in front of it. The gateway now bounds
      // both (audio_output_gateway_test.dart); this proves the gate holds even
      // for a gateway that does not.
      final harness = await _Harness.pump(tester, audio: _SilentAudio());
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntilRiding();

      expect(harness.service.commands, contains('startRide:kalyan->dombivli'));
    });

    testWidgets('and a probe that fails FAILS OPEN: no warning it cannot back', (
      tester,
    ) async {
      // Every probe here already fails open on its own (earphones answer true
      // when the platform will not say), because a false warning before every
      // ride teaches a rider to tap past the screen that matters. A probe that
      // throws or hangs gets the same answer, so the ride goes straight to the
      // commit window with no preflight screen in between.
      final harness = await _Harness.pump(
        tester,
        permissions: _ThrowingPermissions(),
        audio: _SilentAudio(),
      );
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntil(
        () => find.text('Starting Travel Mode').evaluate().isNotEmpty,
      );

      expect(find.text('One thing before you doze off'), findsNothing);
      await harness.runUntilRiding();
    });
  });

  group('after the window closes, a start that fails must still say so', () {
    // THE SAME HOLE ONE STEP LATER. The window has spoken "Starting Travel
    // Mode" and popped, so the rider believes a ride began. Everything in
    // `start()` after that point was uncaught, and `prepareAndStart` then
    // called `showTravelMode`, which returns in silence when no ride is live.
    // The rider was left on Screen 1 having been told a ride started.

    testWidgets('A PERMISSION REQUEST THAT THROWS still reaches a ride', (
      tester,
    ) async {
      // `start()` asks permission_handler for its runtime prompts with no
      // catch. A second request while one is already in flight is a real
      // PlatformException in that plugin, not a hypothetical.
      final harness = await _Harness.pump(
        tester,
        permissionRequestsThrow: true,
      );
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntilRiding();

      expect(harness.service.commands, contains('startRide:kalyan->dombivli'));
    });

    testWidgets(
      'SETTINGS THAT WILL NOT READ still reach a ride, WITH ANALYTICS OFF',
      (tester) async {
        // The ride must not depend on a database read. But the defaults are
        // not a neutral answer here: `AppSettings()` has sharing ON, and a
        // rider who opted out would be reported on the one ride we could not
        // read her choice for. The service client's own default is off for
        // exactly this reason, "rather than sending without consent".
        final harness = await _Harness.pump(tester, settingsBroken: true);
        await harness.standAt(repo, 'kalyan');

        harness.tapDestination('dombivli');
        await harness.runUntilRiding();

        expect(harness.service.shareAnonymousUsagePassed, isFalse);
      },
    );

    testWidgets('A SERVICE THAT THROWS tells her the ride did not start', (
      tester,
    ) async {
      final harness = await _Harness.pump(tester, service: _ThrowingService());
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntil(
        () => find.text(rideDidNotStartMessage).evaluate().isNotEmpty,
      );

      expect(find.text('End journey'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget, reason: 'back home');
    });

    testWidgets('A SERVICE THAT REFUSES tells her the ride did not start', (
      tester,
    ) async {
      // `startService` answers ServiceRequestFailure without throwing, for
      // example when Android refuses a foreground service from the
      // background. That returned false, and false was also silent.
      final harness = await _Harness.pump(tester, service: _RefusingService());
      await harness.standAt(repo, 'kalyan');

      harness.tapDestination('dombivli');
      await harness.runUntil(
        () => find.text(rideDidNotStartMessage).evaluate().isNotEmpty,
      );

      expect(find.text('End journey'), findsNothing);
    });

    testWidgets('AND THE RESUME CARD, the other door into startRide', (
      tester,
    ) async {
      // A guard that covers the path you were looking at is not a guard.
      // `resumeInterrupted` calls the same `startRide` from the same Screen 1,
      // unawaited, and the offer staying on screen is not an answer: it looks
      // exactly like a button that did nothing.
      final service = _ThrowingService()
        ..rideInFlight = true
        ..originId = 'kalyan'
        ..destinationId = 'dombivli'
        ..startedAt = DateTime.now().subtract(const Duration(minutes: 5));
      final harness = await _Harness.pump(tester, service: service);

      await tester.tap(find.byKey(const Key('resume_ride_card')));
      await harness.runUntil(
        () => find.text(rideDidNotStartMessage).evaluate().isNotEmpty,
      );

      expect(
        find.byKey(const Key('resume_ride_card')),
        findsOneWidget,
        reason: 'the offer stays, so she can try again',
      );
    });
  });
}

class _Harness {
  _Harness(this.tester, this.service, this.announcer);

  final WidgetTester tester;
  final FakeRideServiceClient service;
  final _RecordingAnnouncer announcer;

  /// THE REAL APP, entry gate and all, so the tap goes through the same
  /// HomeShell a rider's does. Only the platform is replaced.
  static Future<_Harness> pump(
    WidgetTester tester, {
    FakePermissions? permissions,
    AudioOutputGateway? audio,
    FakeRideServiceClient? service,
    bool permissionRequestsThrow = false,
    bool settingsBroken = false,
  }) async {
    service ??= FakeRideServiceClient();
    final announcer = _RecordingAnnouncer();
    // `start()` asks permission_handler directly for its runtime prompts.
    _grantPermissionChannel(tester, requestsThrow: permissionRequestsThrow);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(
              File(StationRepository.assetPath).readAsStringSync(),
            ),
          ),
          // Screen 1's own fix on open. The test hands it one below instead.
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS under test'),
          ),
          appDatabaseProvider.overrideWith((ref) {
            final db = AppDatabase.inMemory();
            ref.onDispose(db.close);
            return db;
          }),
          onboardingSeenProvider.overrideWith((ref) async => true),
          rideServiceClientProvider.overrideWithValue(service),
          permissionsGatewayProvider.overrideWithValue(
            permissions ?? FakePermissions(alwaysGranted: true),
          ),
          audioOutputGatewayProvider.overrideWithValue(
            audio ?? _ConnectedAudio(),
          ),
          commitAnnouncerProvider.overrideWithValue(announcer),
          if (settingsBroken)
            appSettingsProvider.overrideWith(_BrokenSettings.new),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();
    return _Harness(tester, service, announcer);
  }

  ProviderContainer get _container =>
      ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));

  /// A fix on the platform, through the one gate every fix source uses, so the
  /// origin is filled the way GPS fills it and not by a setter.
  Future<void> standAt(StationRepository repo, String stationId) async {
    await _container.read(stationRepositoryProvider.future);
    final station = repo.stationsById[stationId]!;
    final located = _container
        .read(nearestStationProvider.notifier)
        .applyFix(station.lat, station.lng, 10);
    expect(located, isTrue, reason: 'standing at $stationId');
    await tester.pump();
  }

  /// Exactly what a saved, recent or suggested card does when tapped. Called
  /// on the widget rather than tapped, because which card is on screen depends
  /// on history this harness has no reason to invent.
  void tapDestination(String stationId) =>
      tester.widget<HomeScreen>(find.byType(HomeScreen)).onStartTo(stationId);

  /// Pumps fake time in small steps until [done] or a generous deadline.
  ///
  /// NOT pumpAndSettle. Screen 1 breathes and Screen 3's ring runs, so
  /// "settled" is either never or a coincidence.
  Future<void> runUntil(bool Function() done, {int seconds = 15}) async {
    for (var i = 0; i < seconds * 4; i++) {
      if (done()) return;
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(
      done(),
      isTrue,
      reason:
          'still waiting after ${seconds}s: a dead tap. '
          'preflight=${find.text('One thing before you doze off').evaluate().isNotEmpty} '
          'starting=${find.text('Starting Travel Mode').evaluate().isNotEmpty} '
          'sheet=${find.byType(RoutePickerSheet).evaluate().isNotEmpty} '
          'spoken=${announcer.lines} commands=${service.commands} '
          'texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).take(30).toList()}',
    );
  }

  Future<void> runUntilRiding() => runUntil(
    () =>
        service.commands.any((c) => c.startsWith('startRide:')) &&
        find.text('End journey').evaluate().isNotEmpty,
  );
}

class _RecordingAnnouncer extends CommitAnnouncer {
  final List<String> lines = [];

  @override
  Future<bool> speak(String line, {required AppLanguage language}) async {
    lines.add(line);
    return true;
  }

  @override
  Future<void> warmUp() async {}
}

class _ConnectedAudio extends AudioOutputGateway {
  @override
  Future<bool> earphonesConnected() async => true;
}

/// `AudioSession.instance` as the test binding meets it: asked, and silent.
class _SilentAudio extends AudioOutputGateway {
  @override
  Future<bool> earphonesConnected() => Completer<bool>().future;
}

class _ThrowingPermissions extends FakePermissions {
  @override
  Future<bool> hasAlways() async =>
      throw PlatformException(code: 'channel', message: 'no answer');
}

class _ThrowingService extends FakeRideServiceClient {
  @override
  Future<bool> startRide({
    required String originStationId,
    required String destinationStationId,
    required String notificationText,
    required bool sarvamGreeting,
    required bool sarvamClips,
    required DateTime startedAt,
    int? startBatteryPct,
    int? pulseIntervalSeconds,
    bool pulseVibrate = true,
    bool shareAnonymousUsage = false,
    bool announceEveryStation = true,
    AppLanguage language = AppLanguage.english,
    bool routeAlreadySpoken = false,
    List<String>? routeChainIds,
  }) async => throw PlatformException(code: 'saveData', message: 'store');
}

/// `startService` answering ServiceRequestFailure: no throw, just no ride.
class _RefusingService extends FakeRideServiceClient {
  @override
  Future<bool> startRide({
    required String originStationId,
    required String destinationStationId,
    required String notificationText,
    required bool sarvamGreeting,
    required bool sarvamClips,
    required DateTime startedAt,
    int? startBatteryPct,
    int? pulseIntervalSeconds,
    bool pulseVibrate = true,
    bool shareAnonymousUsage = false,
    bool announceEveryStation = true,
    AppLanguage language = AppLanguage.english,
    bool routeAlreadySpoken = false,
    List<String>? routeChainIds,
  }) async => false;
}

class _BrokenSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => throw StateError('database locked');
}

void _grantPermissionChannel(
  WidgetTester tester, {
  bool requestsThrow = false,
}) {
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    switch (call.method) {
      case 'requestPermissions':
        if (requestsThrow) {
          throw PlatformException(
            code: 'PermissionHandler.PermissionManager',
            message: 'A request for permissions is already running',
          );
        }
        return {for (final p in call.arguments as List) p as int: 1};
      case 'checkPermissionStatus':
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
