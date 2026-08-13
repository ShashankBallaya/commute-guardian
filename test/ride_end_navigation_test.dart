import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/arrival_screen.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/screens/travel_mode_screen.dart';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';

import 'support/fake_ride_service_client.dart';

/// THE PRODUCT STACK, which no widget test had ever assembled.
///
/// Every earlier end-of-ride test mounted the DEBUG screen as the host, and the
/// debug screen sets `resumesTravelModeScreen = false`, so **Screen 4 was never
/// on the navigator** when Screen 5 closed. The product stack is
/// Home -> Screen 4 -> Screen 5, and that third layer is where the bug lives.
///
/// Reported from a real ride on 13 Aug 2026, Shahad to Dombivli: the owner
/// pressed End journey on Screen 5, landed back on **Screen 4**, and had to
/// press End journey a second time. `ride_orchestration.dart` carried a comment
/// asserting the opposite ("Screen 5 over Screen 4 lands on Screen 1 either
/// way"), reasoned rather than measured, and it survived four months.
Future<void> _pumpProductStack(
  WidgetTester tester,
  FakeRideServiceClient service,
) async {
  final raw = File(StationRepository.assetPath).readAsStringSync();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        onboardingSeenProvider.overrideWith((ref) async => true),
        stationRepositoryProvider.overrideWith(
          (ref) async => StationRepository.parse(raw),
        ),
        fixAcquirerProvider.overrideWithValue(
          () async => throw StateError('no GPS under test'),
        ),
        rideServiceClientProvider.overrideWithValue(service),
      ],
      child: const CommuteGuardianDebugApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a running ride puts Screen 4 on the product stack', (
    tester,
  ) async {
    // The precondition for everything below. If this ever fails, the test
    // beneath it is passing for the wrong reason.
    final service = FakeRideServiceClient(
      running: true,
      originId: 'shahad',
      destinationId: 'dombivli',
    );
    await _pumpProductStack(tester, service);

    expect(find.byType(TravelModeScreen), findsOneWidget);
  });

  testWidgets('ENDING FROM SCREEN 5 LANDS ON HOME, not back on Screen 4', (
    tester,
  ) async {
    final service = FakeRideServiceClient(
      running: true,
      originId: 'shahad',
      destinationId: 'dombivli',
    );
    await _pumpProductStack(tester, service);
    expect(find.byType(TravelModeScreen), findsOneWidget);

    service.emit(const DestinationReached());
    await tester.pumpAndSettle();
    expect(find.byType(ArrivalScreen), findsOneWidget);

    // End now, exactly as the rider pressed it on the Dombivli platform.
    service.running = false;
    await tester.tap(find.text('End now'));
    service.emit(const RideEndedByService());
    await tester.pumpAndSettle();

    expect(find.byType(ArrivalScreen), findsNothing);
    expect(
      find.byType(TravelModeScreen),
      findsNothing,
      reason:
          'the ride is over, so the ride screen must not be what the rider '
          'is left holding. This is the 13 Aug bug: one tap ended the ride '
          'and dropped the rider on Screen 4, needing a second End journey.',
    );
    expect(
      find.byType(HomeScreen),
      findsOneWidget,
      reason: 'a finished ride returns the rider to Home',
    );
  });

  test('END JOURNEY CLOSES FIRST AND STILL TIDIES AFTER', () {
    // Split on 13 Aug 2026: the rider used to watch a battery read (allowed
    // two whole seconds) and a database write before Screen 4 would close.
    // Closing first is only safe if the tidying still happens, and losing it
    // would cost the history row silently, which is the half nobody would
    // notice until they opened History a week later.
    final source = File(
      'lib/screens/ride_orchestration.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    final start = source.indexOf('onEndJourney: () async {');
    expect(start, greaterThan(-1), reason: 'the End journey handler is gone');
    final body = source.substring(
      start,
      source.indexOf('\n            },', start),
    );

    final ends = body.indexOf('endRide()');
    final closes = body.indexOf('removeRoute(route)');
    final tidies = body.indexOf('finishRide()');

    expect(ends, greaterThan(-1), reason: 'the ride must actually be stopped');
    expect(closes, greaterThan(ends), reason: 'stop the ride, then close');
    expect(
      tidies,
      greaterThan(closes),
      reason: 'the history row and battery reading come AFTER the screen goes',
    );
  });

  test('and the service-ended path shares that tidying, so the two cannot '
      'drift apart', () {
    final source = File(
      'lib/screens/ride_orchestration.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final start = source.indexOf('Future<void> onRideEndedByService() async {');
    expect(start, greaterThan(-1));
    final body = source.substring(start, source.indexOf('\n  }', start));

    expect(body, contains('finishRide()'));
    expect(
      body,
      isNot(contains('recordRide()')),
      reason: 'a second copy of the tidying is how one path loses a step',
    );
  });
}
