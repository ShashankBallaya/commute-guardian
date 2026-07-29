import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/widgets/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 1, Home.
///
/// The states are keyed to journeys COMPLETED, never to routes saved. That
/// distinction exists because of a hole the owner spotted on 16 Jul 2026: a
/// rider who never saves anything would otherwise be stuck on an empty screen
/// forever, losing the two-tap start the whole screen is designed around.
void main() {
  late String stationsJson;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
  });

  Future<AppDatabase> historyWith(
    List<(String id, String name)> destinations,
  ) async {
    final db = AppDatabase.inMemory();
    var minute = 0;
    for (final (id, name) in destinations) {
      await db.record(
        originId: 'shahad',
        destinationId: id,
        originName: 'Shahad',
        destinationName: name,
        startedAt: DateTime(2026, 7, 28, 9, minute),
        endedAt: DateTime(2026, 7, 28, 10, minute++),
        reachedDestination: true,
        stationCount: 9,
      );
    }
    return db;
  }

  Future<List<String>> pumpHome(
    WidgetTester tester, {
    AppDatabase? history,
  }) async {
    final started = <String>[];
    final db = history ?? AppDatabase.inMemory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider
              .overrideWith((ref) async => StationRepository.parse(stationsJson)),
          fixAcquirerProvider
              .overrideWithValue(() async => throw StateError('no GPS')),
          appDatabaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
        ],
        child: MaterialApp(
          home: HomeScreen(onStartTo: started.add, onNew: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return started;
  }

  testWidgets('first run says what the app does and offers one action', (
    tester,
  ) async {
    await pumpHome(tester);

    expect(
      find.text("Doze off. We'll wake you before your stop."),
      findsOneWidget,
    );
    expect(find.byKey(const Key('start_first_journey')), findsOneWidget);
    // Nothing to be clever about with no history: no cards, no Recent eyebrow.
    expect(find.text('Recent'), findsNothing);
  });

  testWidgets('a rider who has ridden gets their destinations, not the promise',
      (tester) async {
    await pumpHome(
      tester,
      history: await historyWith([('thane', 'Thane'), ('kalyan', 'Kalyan')]),
    );

    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Kalyan'), findsOneWidget);
    expect(find.text('Thane'), findsOneWidget);
    // The first-run copy must not survive into the state that has content.
    expect(
      find.text("Doze off. We'll wake you before your stop."),
      findsNothing,
    );
    expect(find.byKey(const Key('start_first_journey')), findsNothing);
  });

  testWidgets('one tap on a card starts the ride to that destination', (
    tester,
  ) async {
    final started = await pumpHome(
      tester,
      history: await historyWith([('thane', 'Thane')]),
    );

    await tester.tap(find.byKey(const Key('destination_card_thane')));
    await tester.pumpAndSettle();

    // The whole card is the target and it starts a ride. There is deliberately
    // no second control on the row: every card is a live trigger.
    expect(started, ['thane']);
  });

  testWidgets('every tappable surface answers the press', (tester) async {
    // Tapping a card STARTS A JOURNEY, and starting one does database and GPS
    // work, so the gap between the tap and any visible response is long enough
    // for a rider to wonder whether it registered. Each of these was a bare
    // GestureDetector until 29 Jul 2026.
    await pumpHome(
      tester,
      history: await historyWith([('thane', 'Thane')]),
    );

    for (final key in ['destination_card_thane', 'new_journey', 'status_chip']) {
      expect(
        find.ancestor(
          of: find.byKey(Key(key)),
          matching: find.byType(Pressable),
        ).evaluate().isNotEmpty ||
            tester.widget(find.byKey(Key(key))) is Pressable,
        isTrue,
        reason: '$key must give press feedback',
      );
    }
  });

  testWidgets('the first-run CTA answers the press too', (tester) async {
    await pumpHome(tester, history: await historyWith([]));
    expect(
      find.descendant(
        of: find.byKey(const Key('start_first_journey')),
        matching: find.byType(Pressable),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a daily destination appears once, not once per ride', (
    tester,
  ) async {
    await pumpHome(
      tester,
      history: await historyWith([
        ('thane', 'Thane'),
        ('thane', 'Thane'),
        ('thane', 'Thane'),
        ('kalyan', 'Kalyan'),
      ]),
    );

    expect(find.text('Thane'), findsOneWidget);
    expect(find.text('Kalyan'), findsOneWidget);
  });

  testWidgets('the chip reports GPS state, and New journey is always reachable',
      (tester) async {
    await pumpHome(
      tester,
      history: await historyWith([('thane', 'Thane')]),
    );

    // The fix acquirer throws here, the same way an indoor timeout does.
    expect(find.byKey(const Key('status_chip')), findsOneWidget);
    expect(
      find.textContaining('Tap to retry', findRichText: true),
      findsOneWidget,
    );
    expect(find.byKey(const Key('new_journey')), findsOneWidget);
  });
}
