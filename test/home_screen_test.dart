import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/services/journey_suggestion.dart';
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

  /// Taps on the two header destinations, so a test can assert they are wired
  /// without this file having to know what a history screen looks like.
  final taps = <String>[];

  Future<List<String>> pumpHome(
    WidgetTester tester, {
    AppDatabase? history,
    bool header = true,
    JourneySuggestion? suggestion,
  }) async {
    taps.clear();
    final started = <String>[];
    final db = history ?? AppDatabase.inMemory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
          appDatabaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          // Overridden rather than driven through a fake GPS fix and a
          // synthetic history: what these tests are about is what the CARD
          // does, and JourneySuggester's own rules are proved in
          // journey_suggestion_test.dart against the engine directly.
          journeySuggestionProvider.overrideWith((ref) async => suggestion),
        ],
        child: MaterialApp(
          home: HomeScreen(
            onStartTo: started.add,
            onNew: () {},
            onHistory: header ? () => taps.add('history') : null,
            onSettings: header ? () => taps.add('settings') : null,
          ),
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

  testWidgets(
    'a rider who has ridden gets their destinations, not the promise',
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
    },
  );

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
    await pumpHome(tester, history: await historyWith([('thane', 'Thane')]));

    for (final key in [
      'destination_card_thane',
      'new_journey',
      'status_chip',
    ]) {
      expect(
        find
                .ancestor(
                  of: find.byKey(Key(key)),
                  matching: find.byType(Pressable),
                )
                .evaluate()
                .isNotEmpty ||
            tester.widget(find.byKey(Key(key))) is Pressable,
        isTrue,
        reason: '$key must give press feedback',
      );
    }
  });

  testWidgets('the first-run CTA answers the press too', (tester) async {
    await pumpHome(tester, history: await historyWith([]));
    // Asserted the same way as new_journey above, since 11 Aug 2026 they are
    // ONE widget. The key sits on the Pressable itself rather than on a wrapper
    // around it, which is the stronger claim: the keyed thing IS the pressable
    // surface, not merely something with a pressable part somewhere inside.
    expect(
      find.ancestor(
        of: find.byKey(const Key('start_first_journey')),
        matching: find.byType(Pressable),
      ).evaluate().isNotEmpty ||
          find
              .byKey(const Key('start_first_journey'))
              .evaluate()
              .any((e) => e.widget is Pressable),
      isTrue,
      reason: 'the first-run CTA must give press feedback',
    );
    // Trimmed on 1 Aug 2026 along with the rest of the screen, and this is the
    // floor it stopped at. See the touch-minimum test below.
    final cta = tester.getSize(find.byKey(const Key('start_first_journey')));
    expect(cta.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('no tappable surface falls under the 48 dp touch minimum', (
    tester,
  ) async {
    // The buttons were trimmed on 1 Aug 2026 because they read as oversized.
    // This is the floor that trim stopped at, and it is here so the next trim
    // cannot quietly go through it: these are one-handed taps on a platform,
    // often by someone tired, and 48 dp is the accessibility minimum rather
    // than a style preference. The wake alert's own far larger target is
    // guarded separately, in wake_alert_screen_test.
    await pumpHome(tester, history: await historyWith([('thane', 'Thane')]));

    for (final key in [
      'destination_card_thane',
      'new_journey',
      'status_chip',
    ]) {
      final height = tester.getSize(find.byKey(Key(key))).height;
      expect(
        height,
        greaterThanOrEqualTo(48.0),
        reason: '$key is $height dp tall, under the 48 dp touch minimum',
      );
    }
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

  testWidgets(
    'the chip reports GPS state, and New journey is always reachable',
    (tester) async {
      await pumpHome(tester, history: await historyWith([('thane', 'Thane')]));

      // The fix acquirer throws here, the same way an indoor timeout does.
      expect(find.byKey(const Key('status_chip')), findsOneWidget);
      expect(
        find.textContaining('Tap to retry', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(const Key('new_journey')), findsOneWidget);
    },
  );

  testWidgets('the header offers history and settings, and both are wired', (
    tester,
  ) async {
    await pumpHome(tester);

    await tester.tap(find.byKey(const Key('home_history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('home_settings')));
    await tester.pump();

    expect(taps, ['history', 'settings']);
  });

  testWidgets('the header is optional, so the screen stands alone', (
    tester,
  ) async {
    // Nullable on purpose: a test, and any future embedding, can pump Screen 1
    // without inventing two destinations for it to navigate to.
    await pumpHome(tester, header: false);

    expect(find.byKey(const Key('home_history')), findsNothing);
    expect(find.byKey(const Key('home_settings')), findsNothing);
    // And the primary action is still there, which is the point of the screen.
    expect(find.text('Start your first journey'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // State 3, saved routes. Built 5 Aug 2026, the last of Screen 1's three
  // states to exist.
  // ---------------------------------------------------------------------------

  testWidgets('a saved route leads, under the name the rider gave it', (
    tester,
  ) async {
    final db = await historyWith([('kalyan', 'Kalyan'), ('thane', 'Thane')]);
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'kalyan',
      destinationName: 'Kalyan',
    );
    await pumpHome(tester, history: db);

    // The label is the headline because that is the word the rider chose. The
    // station stays under it, because it is the fact that has to be checkable
    // before a tap starts a ride.
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Kalyan'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
  });

  testWidgets('A SAVED DESTINATION IS NEVER OFFERED TWICE', (tester) async {
    // Saving Kalyan as Home and then riding there would otherwise put Kalyan on
    // the screen as both "Home" and "Kalyan": two cards, one behaviour, and a
    // rider left to work out whether they differ.
    final db = await historyWith([('kalyan', 'Kalyan'), ('thane', 'Thane')]);
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'kalyan',
      destinationName: 'Kalyan',
    );
    await pumpHome(tester, history: db);

    expect(find.byKey(const Key('saved_route_card_home')), findsOneWidget);
    expect(find.byKey(const Key('destination_card_kalyan')), findsNothing);
    expect(find.byKey(const Key('destination_card_thane')), findsOneWidget);
  });

  testWidgets('three cards, whatever the mix of saved and recent', (
    tester,
  ) async {
    // The cap is what keeps the cards in the thumb zone. Past three the last
    // one is no longer a one-handed tap, which is the layout's whole reason.
    final db = await historyWith([
      ('kalyan', 'Kalyan'),
      ('thane', 'Thane'),
      ('dadar', 'Dadar'),
      ('mulund', 'Mulund'),
    ]);
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'shahad',
      destinationName: 'Shahad',
    );
    await db.saveRoute(
      label: 'Work',
      destinationStationId: 'csmt',
      destinationName: 'CSMT',
    );
    await pumpHome(tester, history: db);

    expect(find.byKey(const Key('saved_route_card_home')), findsOneWidget);
    expect(find.byKey(const Key('saved_route_card_work')), findsOneWidget);
    // One slot is left, and it goes to the newest ride, which is Mulund.
    expect(find.byKey(const Key('destination_card_mulund')), findsOneWidget);
    expect(find.byKey(const Key('destination_card_dadar')), findsNothing);
    expect(find.byKey(const Key('destination_card_kalyan')), findsNothing);
  });

  testWidgets('a saved card starts the ride to its own destination', (
    tester,
  ) async {
    final db = await historyWith([('thane', 'Thane')]);
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'kalyan',
      destinationName: 'Kalyan',
    );
    final started = await pumpHome(tester, history: db);

    await tester.tap(find.byKey(const Key('saved_route_card_home')));
    await tester.pumpAndSettle();

    // The label is what the rider reads; the station id is what starts.
    expect(started, ['kalyan']);
    final height = tester
        .getSize(find.byKey(const Key('saved_route_card_home')))
        .height;
    expect(height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('A SAVED ROUTE CANNOT BRING BACK THE FIRST-RUN SCREEN', (
    tester,
  ) async {
    // The states are keyed to journeys COMPLETED, never to routes saved, which
    // is the hole the owner caught on 16 Jul 2026. Saving happens at journey
    // end, so this pairing cannot arise on a real phone; the rule is pinned
    // here because the next person to touch this screen will be tempted to
    // read the saved list to decide the state.
    final db = AppDatabase.inMemory();
    await db.saveRoute(
      label: 'Home',
      destinationStationId: 'kalyan',
      destinationName: 'Kalyan',
    );
    await pumpHome(tester, history: db);

    expect(find.text('Start your first journey'), findsOneWidget);
    expect(find.byKey(const Key('saved_route_card_home')), findsNothing);
  });

  group('the "Heading home?" suggestion', () {
    const toDadar = JourneySuggestion(
      destinationId: 'dadar',
      destinationName: 'Dadar',
      matches: 8,
      isHome: false,
    );

    testWidgets('no suggestion leaves the screen exactly as it was', (
      tester,
    ) async {
      // The normal case, by a wide margin. JourneySuggester returns null
      // unless there is real evidence, so most riders most of the time must
      // see the screen that existed before this feature.
      await pumpHome(
        tester,
        history: await historyWith([('kalyan', 'Kalyan')]),
      );
      expect(find.byKey(const Key('suggestion_card')), findsNothing);
      expect(find.textContaining('Heading'), findsNothing);
    });

    testWidgets('a suggestion that is not home names the station instead', (
      tester,
    ) async {
      // History is required, and not as ceremony: Screen 1 shows the first-run
      // state until a journey has completed, and a suggestion is DERIVED from
      // completed journeys, so "a suggestion with no history" is a state that
      // cannot occur. The first draft of these tests built exactly that and
      // failed correctly.
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
        suggestion: toDadar,
      );
      expect(find.text('Heading to Dadar?'), findsOneWidget);
      expect(find.text('Heading home?'), findsNothing);
    });

    testWidgets('IT ONLY SAYS HOME WHEN HOME IS WHAT THE RIDER LABELLED', (
      tester,
    ) async {
      // Its own test rather than a second pump in the one above: pumping a
      // fresh ProviderScope over an existing element tree does not reliably
      // re-resolve an overridden autoDispose provider, so the two-pump version
      // failed on the second half while the code was correct.
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
        suggestion: const JourneySuggestion(
          destinationId: 'dadar',
          destinationName: 'Dadar',
          matches: 8,
          isHome: true,
        ),
      );
      expect(find.text('Heading home?'), findsOneWidget);
      // Still names the station underneath, because a card that starts a ride
      // has to be checkable before it is tapped.
      expect(find.textContaining('Dadar'), findsWidgets);
    });

    testWidgets('it says why, so the rider can disagree with it', (
      tester,
    ) async {
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
        suggestion: toDadar,
      );
      expect(find.textContaining('usually'), findsOneWidget);
    });

    testWidgets('tapping it starts that ride and nothing else', (tester) async {
      final started = await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
        suggestion: toDadar,
      );
      await tester.tap(find.byKey(const Key('suggestion_card')));
      await tester.pumpAndSettle();
      expect(started, ['dadar']);
    });

    testWidgets('THE SAME DESTINATION NEVER APPEARS TWICE', (tester) async {
      // A rider looking at two cards for Dadar has to work out whether they
      // differ, on a platform, which is the one moment this screen exists to
      // be obvious in.
      await pumpHome(
        tester,
        history: await historyWith([('dadar', 'Dadar'), ('thane', 'Thane')]),
        suggestion: toDadar,
      );
      expect(find.byKey(const Key('suggestion_card')), findsOneWidget);
      expect(find.byKey(const Key('destination_card_dadar')), findsNothing);
      // The other recent is untouched.
      expect(find.byKey(const Key('destination_card_thane')), findsOneWidget);
    });
  });

  group('crimson means END A RIDE, and Screen 1 ends nothing', () {
    // The rule, narrowed by the owner 11 Aug 2026 from "start or end a
    // journey", which gave one colour two opposite meanings. Screen 1's
    // first-run CTA was the app's only violation and is now white.
    //
    // Pinned as a test rather than left to the Palette doc, because the doc is
    // what the previous version of this rule was written in and it did not stop
    // the exception being shipped.
    Future<void> expectNoCrimson(WidgetTester tester) async {
      final crimson = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final decoration = c.decoration;
            return decoration is BoxDecoration &&
                decoration.color == const Color(0xFF55131D);
          });
      expect(
        crimson,
        isEmpty,
        reason: 'nothing on Screen 1 ends a ride, so nothing may be crimson',
      );
    }

    /// The CTA is white, 0xFFFEFEFE, which is [Palette.accent] and the app's
    /// single white. Checked alongside the crimson absence in both states,
    /// because "not crimson" alone would pass on a button that had gone grey.
    void expectAccentFill(WidgetTester tester) {
      final accent = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final decoration = c.decoration;
            return decoration is BoxDecoration &&
                decoration.color == const Color(0xFFFEFEFE);
          });
      expect(accent, isNotEmpty, reason: 'the CTA must carry the white fill');
    }

    testWidgets('the first-run state is white, not crimson', (tester) async {
      await pumpHome(tester, history: await historyWith([]));
      expect(find.byKey(const Key('start_first_journey')), findsOneWidget);
      await expectNoCrimson(tester);
      expectAccentFill(tester);
    });

    testWidgets('the list state is white too, and always was', (tester) async {
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
      );
      expect(find.byKey(const Key('new_journey')), findsOneWidget);
      await expectNoCrimson(tester);
      expectAccentFill(tester);
    });
  });
}
