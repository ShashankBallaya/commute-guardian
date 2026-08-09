import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/journey.dart';
import 'package:commute_guardian/screens/travel_mode_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 4, Travel Mode. Frame approved 16 Jul 2026 (v2), built 29 Jul.
///
/// Everything here is drawn from ONE number, reachedIndex, published by the
/// service's own RideProgress. There is no second projector.
void main() {
  late StationRepository repo;
  late Journey journey;

  setUpAll(() {
    repo = StationRepository.parse(
      File(StationRepository.assetPath).readAsStringSync(),
    );
    journey = repo.planner.plan(originId: 'thane', destinationId: 'kalyan');
  });

  Future<({List<WakeChoice> choices, List<int> ends})> pump(
    WidgetTester tester, {
    required int reachedIndex,
    bool atStation = false,
    WakeChoice choice = WakeChoice.lastTwoStations,
    String? etaLine,
  }) async {
    final choices = <WakeChoice>[];
    final ends = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TravelModeScreen(
          journey: journey,
          reachedIndex: reachedIndex,
          atStation: atStation,
          wakeChoice: choice,
          etaLine: etaLine,
          onWakeChoiceChanged: choices.add,
          onEndJourney: () => ends.add(1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (choices: choices, ends: ends);
  }

  testWidgets('the countdown is what is still ahead, not what has passed', (
    tester,
  ) async {
    // Thane to Kalyan. At the origin nothing is reached yet, so every station
    // after it is still to come.
    await pump(tester, reachedIndex: 0);
    final remaining = journey.chain.length - 1;
    expect(find.text('$remaining'), findsOneWidget);
    expect(find.text('stations to'), findsOneWidget);
    expect(find.text('Kalyan'), findsOneWidget);
  });

  testWidgets('one station left reads "station", not "stations"', (
    tester,
  ) async {
    await pump(tester, reachedIndex: journey.chain.length - 2);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('station to'), findsOneWidget);
    expect(find.text('stations to'), findsNothing);
  });

  testWidgets('the ride collapses where it has been and names where it is', (
    tester,
  ) async {
    await pump(tester, reachedIndex: 3);
    // Three behind the one it names in full.
    expect(find.text('3 stations passed'), findsOneWidget);
    expect(find.text(journey.chain[3].name), findsOneWidget);
    expect(find.text('You are here'), findsOneWidget);
  });

  testWidgets('at the very start there is nothing to collapse', (tester) async {
    await pump(tester, reachedIndex: -1);
    expect(find.textContaining('stations passed'), findsNothing);
    expect(find.text('You are here'), findsOneWidget);
  });

  testWidgets('the destination is marked as the rider\'s stop', (tester) async {
    await pump(tester, reachedIndex: 0);
    expect(find.text('Kalyan (your stop)'), findsOneWidget);
  });

  testWidgets('THERE IS NO ETA, and no invented one either', (tester) async {
    // Scoped to Phase 3 on 29 Jul. A wrong arrival time on this screen is worse
    // than none: the whole product is a promise about when to wake up.
    await pump(tester, reachedIndex: 2);
    expect(find.textContaining('estimate'), findsNothing);
    expect(find.textContaining('Arriving'), findsNothing);
  });

  testWidgets('the ETA seam renders when Phase 3 fills it', (tester) async {
    await pump(tester, reachedIndex: 2, etaLine: 'Arriving 19:52 (estimate)');
    expect(find.text('Arriving 19:52 (estimate)'), findsOneWidget);
  });

  testWidgets('the wake choice reports both ways', (tester) async {
    final r = await pump(tester, reachedIndex: 2);
    await tester.tap(find.byKey(const Key('wake_only_destination')));
    await tester.pumpAndSettle();
    expect(r.choices, [WakeChoice.onlyDestination]);
  });

  testWidgets('a tap never ends the journey, only a full hold does', (
    tester,
  ) async {
    // The rider is asleep with the phone in a pocket. An accidental brush must
    // not end the ride that is watching for their stop.
    final r = await pump(tester, reachedIndex: 2);

    await tester.tap(find.byKey(const Key('end_journey')));
    await tester.pumpAndSettle();
    expect(r.ends, isEmpty, reason: 'a tap is not a confirmation');

    // A FLUTTER LONG PRESS IS NOT ENOUGH, and that is the fix this pins. It
    // lands at ~500 ms while the fill runs for 1200 ms, so the journey used to
    // end when the bar was about 40 percent across: the screen promised one
    // thing and the button did another.
    await tester.longPress(find.byKey(const Key('end_journey')));
    await tester.pumpAndSettle();
    expect(
      r.ends,
      isEmpty,
      reason: 'releasing before the fill completes must not end the ride',
    );

    // Held for the whole fill.
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('end_journey'))),
    );
    await tester.pump(const Duration(milliseconds: 1300));
    await hold.up();
    await tester.pumpAndSettle();
    expect(r.ends, hasLength(1));
  });

  testWidgets('letting go part way cancels, and nothing is confirmed later', (
    tester,
  ) async {
    // A rider who starts the hold and changes their mind must not have the ride
    // end on them a second later.
    final r = await pump(tester, reachedIndex: 2);

    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('end_journey'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    expect(r.ends, isEmpty);
  });

  testWidgets('it fits a 3T, which the 390pt frame does not prove', (
    tester,
  ) async {
    // The approved frame is 390x844, a TALL phone. The 3T is 1080x1920, which
    // is relatively shorter and narrower, and the first build overflowed there:
    // the wake row wrapped onto three lines and squeezed its own toggle. Same
    // class as the 81 px onboarding overflow on 28 Jul, which no test caught.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final longest = repo.planner.plan(
      originId: 'thane',
      destinationId: 'kasara',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TravelModeScreen(
          journey: longest,
          reachedIndex: 2,
          wakeChoice: WakeChoice.lastTwoStations,
          onWakeChoiceChanged: (_) {},
          onEndJourney: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The label must not wrap: it is what pushed the toggle off the row.
    final label = tester.widget<Text>(find.text('Wake me up'));
    expect(label.maxLines, 1);
    // Both segments still reachable and tappable.
    expect(find.byKey(const Key('wake_last_two')), findsOneWidget);
    expect(find.byKey(const Key('wake_only_destination')), findsOneWidget);
    expect(find.byKey(const Key('end_journey')), findsOneWidget);
  });

  testWidgets('a long chain scrolls inside the card, it does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Thane to Kasara is one of the longest legs on the network.
    final longest = repo.planner.plan(
      originId: 'thane',
      destinationId: 'kasara',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TravelModeScreen(
          journey: longest,
          reachedIndex: 1,
          wakeChoice: WakeChoice.onlyDestination,
          onWakeChoiceChanged: (_) {},
          onEndJourney: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('the shield says the app is watching', (tester) async {
    await pump(tester, reachedIndex: 2);
    expect(find.text('Wake-up\nmode active'), findsOneWidget);
  });

  group('AT a station reads differently from PAST it', () {
    // THE 9 AUG 2026 RIDE, reported by the owner from the platform: the train
    // stood at Vithalwadi and the screen said he was somewhere after it. The
    // chain is Thane to Kalyan here, so index 1 is Kalwa.

    testWidgets('standing in a station names it as the position', (
      tester,
    ) async {
      await pump(tester, reachedIndex: 1, atStation: true);

      final station = journey.chain[1].name;
      expect(find.text(station), findsOneWidget);
      // ONE row, not two. Naming the station IS the position, so a separate
      // "You are here" underneath it would be the same claim twice, and the
      // second one would be wrong.
      expect(find.text('You are here'), findsNothing);
    });

    testWidgets('between two stations still says you are here', (tester) async {
      await pump(tester, reachedIndex: 1, atStation: false);

      expect(find.text(journey.chain[1].name), findsOneWidget);
      expect(find.text('You are here'), findsOneWidget);
    });

    testWidgets('leaving the platform swaps one state for the other', (
      tester,
    ) async {
      // The transition the rider actually watches: doors close, train pulls
      // out, and the screen has to stop claiming the platform.
      await pump(tester, reachedIndex: 1, atStation: true);
      expect(find.text('You are here'), findsNothing);

      await pump(tester, reachedIndex: 1, atStation: false);
      expect(find.text('You are here'), findsOneWidget);
    });
  });
}
