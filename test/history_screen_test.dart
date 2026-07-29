import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';
import 'package:commute_guardian/screens/history_screen.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

/// Screen 7, History. A record, not a shortcut: the rows carry no fill because
/// a filled surface promises a tap and nothing here takes one.
void main() {
  Future<AppDatabase> pumpHistory(
    WidgetTester tester, {
    required List<
        ({String from, String to, DateTime start, DateTime end, int stations, bool reached})>
        rides,
  }) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    for (final r in rides) {
      await db.record(
        originId: r.from.toLowerCase(),
        destinationId: r.to.toLowerCase(),
        originName: r.from,
        destinationName: r.to,
        startedAt: r.start,
        endedAt: r.end,
        reachedDestination: r.reached,
        stationCount: r.stations,
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
        ],
        child: const MaterialApp(home: HistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  testWidgets('a ride reads as route, duration and what became of it', (
    tester,
  ) async {
    await pumpHistory(tester, rides: [
      (
        from: 'Thane',
        to: 'Kalyan',
        start: DateTime(2026, 7, 22, 18, 35),
        end: DateTime(2026, 7, 22, 19, 24),
        stations: 8,
        reached: true,
      ),
    ]);

    expect(find.textContaining('Thane'), findsOneWidget);
    expect(find.text('49 min'), findsOneWidget);
    // "reached" is the only field that says whether the app did its job, which
    // is why it survived the cut that dropped the battery readings. It sits
    // OUTSIDE the bullet run so it can carry its own emphasis.
    expect(
      find.textContaining('Wed 22 Jul • 19:24 • 8 stations', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('reached', findRichText: true), findsOneWidget);
  });

  testWidgets('a reached ride stays quiet and an early end does not', (
    tester,
  ) async {
    // The exception is what gets the brightness. A rider scanning for the ride
    // that went wrong should not have to read past the ones that went right.
    await pumpHistory(tester, rides: [
      (
        from: 'Thane',
        to: 'Kalyan',
        start: DateTime(2026, 7, 22, 18, 35),
        end: DateTime(2026, 7, 22, 19, 24),
        stations: 8,
        reached: true,
      ),
      (
        from: 'Shahad',
        to: 'Ambivli',
        start: DateTime(2026, 7, 23, 14, 51),
        end: DateTime(2026, 7, 23, 14, 55),
        stations: 2,
        reached: false,
      ),
    ]);

    Color? outcomeColour(String label) {
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final root = t.textSpan;
        if (root == null) continue;
        Color? found;
        root.visitChildren((span) {
          if (span is TextSpan && span.text == label) {
            found = span.style?.color;
            return false;
          }
          return true;
        });
        if (found != null) return found;
      }
      return null;
    }

    final reached = outcomeColour('reached');
    final endedEarly = outcomeColour('ended early');
    expect(reached, isNotNull);
    expect(endedEarly, isNotNull);
    expect(
      endedEarly!.a,
      greaterThan(reached!.a),
      reason: 'the ride that failed must be the brighter of the two',
    );
  });

  testWidgets('a ride that did not get there says so', (tester) async {
    await pumpHistory(tester, rides: [
      (
        from: 'Shahad',
        to: 'Ambivli',
        start: DateTime(2026, 7, 23, 14, 51),
        end: DateTime(2026, 7, 23, 14, 55),
        stations: 2,
        reached: false,
      ),
    ]);

    expect(
      find.textContaining('Thu 23 Jul • 14:55 • 2 stations', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('ended early', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('4 min'), findsOneWidget);
  });

  testWidgets('a ride under a minute is named, not floored to zero', (
    tester,
  ) async {
    // Seen on the 3T on 29 Jul: three bench runs all rendered "0 min", which
    // reads as a field that failed to load rather than a very short ride. A
    // rider who starts a journey and cancels on the platform gets this too.
    await pumpHistory(tester, rides: [
      (
        from: 'Shahad',
        to: 'Kalyan',
        start: DateTime(2026, 7, 28, 22, 1, 5),
        end: DateTime(2026, 7, 28, 22, 1, 49),
        stations: 2,
        reached: false,
      ),
    ]);
    expect(find.text('under a minute'), findsOneWidget);
    expect(find.text('0 min'), findsNothing);
  });

  testWidgets('newest first, which is the whole point of a history', (
    tester,
  ) async {
    await pumpHistory(tester, rides: [
      (
        from: 'Shahad',
        to: 'Ambivli',
        start: DateTime(2026, 7, 23, 14, 51),
        end: DateTime(2026, 7, 23, 14, 55),
        stations: 2,
        reached: false,
      ),
      (
        from: 'Shahad',
        to: 'Thane',
        start: DateTime(2026, 7, 23, 15, 0),
        end: DateTime(2026, 7, 23, 15, 4),
        stations: 2,
        reached: false,
      ),
    ]);

    // The approved frame had its top row out of order; the query does not.
    // Read through textSpan, not .data: the meta line is rich text since the
    // outcome left the bullet run, and .data is null for a Text.rich, so a
    // .data-based filter would quietly match nothing and pass on an empty set.
    final meta = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText())
        .whereType<String>()
        .where((s) => s.contains('•'))
        .toList();
    expect(meta, hasLength(2));
    expect(meta.first, contains('15:04'));
    expect(meta.last, contains('14:55'));
  });

  testWidgets('an hour-long ride reads in hours', (tester) async {
    await pumpHistory(tester, rides: [
      (
        from: 'CSMT',
        to: 'Kasara',
        start: DateTime(2026, 7, 20, 8, 0),
        end: DateTime(2026, 7, 20, 10, 12),
        stations: 37,
        reached: true,
      ),
    ]);
    expect(find.text('2 h 12 min'), findsOneWidget);
  });

  testWidgets('no rides yet is a sentence, not a blank screen', (tester) async {
    await pumpHistory(tester, rides: []);
    expect(
      find.text('No journeys yet. Ride one and it will appear here.'),
      findsOneWidget,
    );
  });

  testWidgets('there is a way back out', (tester) async {
    await pumpHistory(tester, rides: []);
    expect(find.byKey(const Key('history_back')), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('the debug screen reaches it', (tester) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
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
          fixAcquirerProvider
              .overrideWithValue(() async => throw StateError('no GPS')),
          rideServiceClientProvider.overrideWithValue(FakeRideServiceClient()),
        ],
        child: const CommuteGuardianDebugApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('history_button')));
    await tester.pumpAndSettle();

    expect(find.byType(HistoryScreen), findsOneWidget);
  });
}
