import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/screens/destination_picker_screen.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/widgets/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 2, the destination picker. Approved 28 Jul 2026.
///
/// The rules under test are the ones the design review settled, not layout:
/// matches replace recents the moment a query exists, every row is a live
/// trigger, and search reaches names in three scripts plus the railway code.
void main() {
  late String stationsJson;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
  });

  Future<List<Station>> pumpPicker(
    WidgetTester tester, {
    String? originId,
    List<(String id, String name)> history = const [],
  }) async {
    final picked = <Station>[];
    final db = AppDatabase.inMemory();
    var minute = 0;
    for (final (id, name) in history) {
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          appDatabaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
        ],
        child: MaterialApp(home: DestinationPickerScreen(onPicked: picked.add)),
      ),
    );
    await tester.pumpAndSettle();
    if (originId != null) {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DestinationPickerScreen)),
      );
      container.read(journeyDraftProvider.notifier).setOrigin(originId);
      await tester.pumpAndSettle();
    }
    return picked;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const Key('destination_search')), query);
    await tester.pumpAndSettle();
  }

  testWidgets('the hint says which end this screen sets', (tester) async {
    await pumpPicker(tester);
    expect(find.text('Where to?'), findsOneWidget);
    expect(find.text('New journey'), findsOneWidget);
  });

  testWidgets('typing replaces recents with matches, eyebrow and all', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      history: [('thane', 'Thane'), ('kalyan', 'Kalyan')],
    );
    expect(find.text('Recent'), findsOneWidget);

    await type(tester, 'Kal');

    // The blocker from the 28 Jul review: a "Recent" eyebrow over rows that do
    // not contain the query reads as a broken filter, so it goes.
    expect(find.text('Recent'), findsNothing);
    // Kalwa sits with Kalyan on purpose: the pair a half-asleep rider must not
    // confuse, which is what the code column is there to separate.
    expect(find.text('Kalyan'), findsOneWidget);
    expect(find.text('Kalwa'), findsOneWidget);
    expect(find.text('Kalamboli'), findsOneWidget);
    expect(find.text('Thane'), findsNothing);
  });

  testWidgets('a code finds the one station holding it', (tester) async {
    await pumpPicker(tester);
    await type(tester, 'Kyn');

    expect(find.text('Kalyan'), findsOneWidget);
    expect(find.text('Kalwa'), findsNothing);
    // The code is on the platform boards, so it appears beside the name.
    expect(find.text('KYN'), findsOneWidget);
  });

  testWidgets('search is substring, not prefix', (tester) async {
    await pumpPicker(tester);
    await type(tester, 'tha');

    expect(find.text('Thane'), findsOneWidget);
    // Matches mid-word. Correct, and worth pinning so it is not "fixed" later.
    expect(find.text('Vithalwadi'), findsOneWidget);
  });

  testWidgets('Devanagari reaches a station too', (tester) async {
    await pumpPicker(tester);
    await type(tester, 'कल्याण');
    expect(find.text('Kalyan'), findsOneWidget);
  });

  testWidgets('a typo finds nothing, and says so', (tester) async {
    await pumpPicker(tester);
    await type(tester, 'Kalyn');

    expect(find.text('Kalyan'), findsNothing);
    expect(find.text('No station by that name.'), findsOneWidget);
  });

  testWidgets('one tap on a row picks that destination', (tester) async {
    final picked = await pumpPicker(tester);
    await type(tester, 'Kyn');

    await tester.tap(find.byKey(const Key('station_row_kalyan')));
    await tester.pumpAndSettle();

    // The whole row is the trigger and nothing else lives on it, which is why
    // the save star was removed.
    expect(picked.map((s) => s.id), ['kalyan']);
  });

  testWidgets('a row answers the press before the ride starts', (tester) async {
    // The highest-stakes tap on this screen: it picks the destination AND the
    // caller starts the ride. It was a bare GestureDetector until 29 Jul 2026,
    // so it gave the rider nothing back. A row tints rather than scaling: a
    // scale would pull it away from the card edges it is aligned to.
    await pumpPicker(tester);
    await type(tester, 'Kyn');

    final row = find.byKey(const Key('station_row_kalyan'));
    expect(tester.widget(row), isA<PressableRow>());

    Color rowTint() {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(of: row, matching: find.byType(AnimatedContainer)),
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    expect(rowTint().a, 0.0);
    final press = await tester.startGesture(tester.getCenter(row));
    // Past kPressTimeout: onTapDown is not reported before then.
    await tester.pump(const Duration(milliseconds: 150));
    expect(rowTint().a, greaterThan(0.0));
    await press.up();
    await tester.pumpAndSettle();
  });

  testWidgets('THE STATION THE RIDER IS STANDING ON TAKES NO TAP', (
    tester,
  ) async {
    // A ride to where you already are is refused by JourneyPlanner, so this row
    // used to do nothing at all when pressed, on a screen where every other row
    // starts a journey. It is not an exotic tap either: the resting list leads
    // with the rider's own line, so their own station is right there.
    final picked = await pumpPicker(tester, originId: 'shahad');

    // Present, not hidden. Hiding it from a list of their own line would read
    // as missing data and send them searching for it.
    expect(find.text('Shahad'), findsOneWidget);
    expect(find.text("You're here"), findsOneWidget);

    await tester.tap(find.byKey(const Key('station_row_shahad')));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);

    // And the rest of the list is untouched.
    await tester.tap(find.byKey(const Key('station_row_kalyan')));
    await tester.pumpAndSettle();
    expect(picked.map((s) => s.id), ['kalyan']);
  });

  testWidgets('the same row is marked in search results too', (tester) async {
    // The rider can reach their own station by typing it, and the answer has to
    // be the same one the resting list gives.
    await pumpPicker(tester, originId: 'shahad');
    await type(tester, 'Shahad');

    expect(find.text("You're here"), findsOneWidget);
  });

  testWidgets("the resting list leads with the rider's own line", (
    tester,
  ) async {
    // Shahad is on the Kasara branch alone, so exactly one line card.
    await pumpPicker(tester, originId: 'shahad');

    expect(find.textContaining(' line'), findsOneWidget);
    expect(find.text('All stations'), findsNothing);
  });

  testWidgets('a junction start merges its lines into one card, not three', (
    tester,
  ) async {
    // Kalyan sits on three Line records (the trunk, Kasara and Karjat) and all
    // three are called "Central". One card per record would render three
    // identical "Central line" eyebrows over overlapping lists, which is what
    // the first version of this screen did.
    await pumpPicker(tester, originId: 'kalyan');

    expect(find.text('Central line'), findsOneWidget);
    // And the merge is real: Kasara and Karjat are on branches Shahad's trunk
    // card would not carry, so their presence proves the union happened.
    expect(find.text('Kasara'), findsOneWidget);
  });

  testWidgets('with no fix yet, every station is still reachable', (
    tester,
  ) async {
    await pumpPicker(tester);
    expect(find.text('All stations'), findsOneWidget);
  });
}
