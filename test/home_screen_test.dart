import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/services/journey_suggestion.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/widgets/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

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
    // The service store, present only for the tests about a ride the OS
    // killed. Left out everywhere else so the offer cannot appear in a test
    // that is about something other than it: with no client override the real
    // one throws under this binding, the notifier catches it, and the screen is
    // exactly the screen it was before this feature existed.
    FakeRideServiceClient? service,
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
          if (service != null)
            rideServiceClientProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: HomeScreen(
            onStartTo: started.add,
            onNew: () {},
            onResumeRide: () => taps.add('resume'),
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

    // THE HEADER ICONS WERE MISSING FROM THIS LIST until 12 Aug 2026, and they
    // were 42 dp: the one rule this project calls accessibility rather than
    // taste was broken in the only two places this test could not see. A floor
    // test that does not name every tappable surface is a floor with a hole in
    // it.
    for (final key in [
      'destination_card_thane',
      'new_journey',
      'status_chip',
      'home_history',
      'home_settings',
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

  group('APPLE-DESIGN PASS, 12 Aug 2026', () {
    testWidgets('THE CARD AND THE CTA ARE THE SAME HEIGHT', (tester) async {
      // The owner said the recent cards looked bigger than New journey. They
      // were: 58.3 dp against 51.3 dp, measured off the device. Nobody had
      // decided that. Both used the same padding and the whole difference came
      // from the card's title being TypeScale.title at w700 while the button's
      // label is bodyLarge at w600, a type choice made for another reason.
      //
      // Seven dp is below the threshold where a size difference reads as
      // hierarchy, so it read as sloppiness instead. Colour carries the
      // difference between them; height does not.
      //
      // THIS TEST IS THE GUARD, not the constant it holds. Change either type
      // size and this fails, which forces the next person to decide the
      // relationship rather than inherit a number.
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
      );

      final card = tester
          .getSize(find.byKey(const Key('destination_card_thane')))
          .height;
      final cta = tester.getSize(find.byKey(const Key('new_journey'))).height;

      // 1.5 dp of tolerance, and the reason is a known property of this
      // harness rather than slack: widget tests render in a square-glyph
      // FALLBACK FONT whose line metrics are not Roboto's (recorded 5 Aug 2026
      // when overflow_test was written). The same code measures 58.3 and 58.3
      // on the 3T and 63.0 and 62.0 here. Exact equality is a device
      // measurement; what this guard exists to catch is the 7 dp regression.
      expect(
        cta,
        closeTo(card, 1.5),
        reason: 'card is $card dp and the CTA is $cta dp; they are peers in '
            'one stack and must share a rhythm',
      );
    });


    testWidgets('STARTING A RIDE TICKS, because it is the commit that matters', (
      tester,
    ) async {
      // Utility: spend haptics on moments that matter. Until this pass a
      // crowd-mode toggle in Settings ticked and handing your stop to your
      // pocket did not. It must be the SYSTEM selection tick and never a
      // vibration pattern: this app's own buzzes mean things, and a UI control
      // may not speak the wake alarm's vocabulary.
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add('${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final started = await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
      );
      await tester.tap(find.byKey(const Key('destination_card_thane')));
      await tester.pumpAndSettle();

      expect(started, ['thane']);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('THE CARDS ENTER ONCE, not on every rebuild', (tester) async {
      // The entrance is an entrance. Screen 1 rebuilds whenever the GPS chip
      // changes or the database answers, and a list that re-faded on each of
      // those would flicker under the rider's thumb on the screen whose whole
      // job is two taps.
      await pumpHome(
        tester,
        history: await historyWith([('thane', 'Thane')]),
      );
      await tester.pumpAndSettle();

      Opacity opacityOf() => tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const Key('destination_card_thane')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacityOf().opacity, 1.0, reason: 'settled after the entrance');

      // Force a rebuild the way a landing GPS fix would.
      await tester.tap(find.byKey(const Key('status_chip')));
      await tester.pump();

      expect(
        opacityOf().opacity,
        1.0,
        reason: 'a rebuild must not restart the entrance',
      );
    });
  });

  group('the ride the OS killed', () {
    /// The store as a jetsammed process left it: a ride in flight, no service.
    FakeRideServiceClient killed({
      bool rideInFlight = true,
      bool running = false,
      Duration ago = const Duration(minutes: 20),
    }) => FakeRideServiceClient(
      running: running,
      rideInFlight: rideInFlight,
      originId: 'shahad',
      destinationId: 'thane',
      startedAt: DateTime.now().subtract(ago),
    );

    testWidgets('is offered back by name, above everything else', (
      tester,
    ) async {
      await pumpHome(
        tester,
        history: await historyWith([('kalyan', 'Kalyan')]),
        service: killed(),
      );

      expect(find.text('Unfinished ride'), findsOneWidget);
      expect(find.text('Still going to Thane?'), findsOneWidget);
      expect(
        find.text('Travel Mode stopped before you got there'),
        findsOneWidget,
      );

      // ABOVE the ordinary cards, which is the whole placement rule: a ride
      // that is already happening outranks an offer to start a new one.
      final offer = tester.getTopLeft(find.byKey(const Key('resume_ride_card')));
      final recent = tester.getTopLeft(
        find.byKey(const Key('destination_card_kalyan')),
      );
      expect(offer.dy, lessThan(recent.dy));
    });

    testWidgets('an ordinary launch is offered nothing', (tester) async {
      // The healthy state, and it is nearly every launch. A ride the rider
      // ended leaves the flag false.
      await pumpHome(tester, service: killed(rideInFlight: false));

      expect(find.text('Unfinished ride'), findsNothing);
      expect(find.byKey(const Key('resume_ride_card')), findsNothing);
    });

    testWidgets('a ride still running is not offered back', (tester) async {
      // It is not interrupted, it is happening. The shell puts this rider on
      // Screen 4 instead, and offering to resume it would start a second
      // service beside the first.
      await pumpHome(tester, service: killed(running: true));

      expect(find.byKey(const Key('resume_ride_card')), findsNothing);
    });

    testWidgets('a ride too old to trust is not offered back', (tester) async {
      await pumpHome(tester, service: killed(ago: const Duration(hours: 4)));

      expect(find.byKey(const Key('resume_ride_card')), findsNothing);
    });

    testWidgets('tapping the card asks to resume', (tester) async {
      await pumpHome(tester, service: killed());

      await tester.tap(find.byKey(const Key('resume_ride_card')));
      await tester.pumpAndSettle();

      expect(taps, ['resume']);
    });

    testWidgets('declining takes the offer away and forgets the ride', (
      tester,
    ) async {
      // THE RIDER CHOOSES, and choosing no has to stick: they may have
      // finished the trip another way, and being asked again at every launch
      // for the next three hours is how a rider learns to ignore this screen.
      final service = killed();
      await pumpHome(tester, service: service);
      expect(find.byKey(const Key('resume_ride_card')), findsOneWidget);

      await tester.tap(find.byKey(const Key('decline_resume_ride')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resume_ride_card')), findsNothing);
      // The STORE, not just this screen: the next launch reads the store.
      expect(service.commands, contains('clearRideInFlight'));
      expect(service.rideInFlight, isFalse);
      // And it did NOT start a ride on the way out.
      expect(taps, isEmpty);
    });

    testWidgets('neither of its controls goes under the touch floor', (
      tester,
    ) async {
      await pumpHome(tester, service: killed());

      for (final key in ['resume_ride_card', 'decline_resume_ride']) {
        final height = tester.getSize(find.byKey(Key(key))).height;
        expect(
          height,
          greaterThanOrEqualTo(48.0),
          reason: '$key is $height dp tall, under the 48 dp touch minimum',
        );
      }
    });
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

    // THE HEADER ICONS WERE MISSING FROM THIS LIST until 12 Aug 2026, and both
    // measured 42 dp: the one rule this project calls accessibility rather than
    // taste was broken in the only two places this test could not see. A floor
    // test that does not name every tappable surface is a floor with a hole in
    // it.
    for (final key in [
      'destination_card_thane',
      'new_journey',
      'status_chip',
      'home_history',
      'home_settings',
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
