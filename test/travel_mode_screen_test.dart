import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/journey.dart';
import 'package:commute_guardian/screens/travel_mode_screen.dart';
import 'package:commute_guardian/widgets/pulse_switch.dart';
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

  Future<({List<int> ends})> pump(
    WidgetTester tester, {
    required int reachedIndex,
    bool atStation = false,
    WakeChoice choice = WakeChoice.lastTwoStations,
    String? etaLine,
    bool wakeEnabled = true,
    List<bool>? wakeTaps,
    bool crowdMode = false,
    int? pulseIntervalSeconds = 180,
    List<bool>? crowdTaps,
  }) async {
    final ends = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TravelModeScreen(
          wakeEnabled: wakeEnabled,
          onWakeEnabled: (on) => wakeTaps?.add(on),
          crowdMode: crowdMode,
          pulseIntervalSeconds: pulseIntervalSeconds,
          onCrowdMode: (on) => crowdTaps?.add(on),
          journey: journey,
          reachedIndex: reachedIndex,
          atStation: atStation,
          wakeChoice: choice,
          etaLine: etaLine,
          onEndJourney: () => ends.add(1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (ends: ends);
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

  group('THE WAKE CARD STATES THE RULE, it does not offer a choice', () {
    // The segmented control was removed on 11 Aug 2026: it changed nothing (the
    // ladder runs on locked rules), a tap could not even redraw the screen, and
    // choosing the distance is a Guardian Plus surface. A control that invites a
    // tap and ignores it is worse than no control on the screen a half-asleep
    // rider is holding.

    testWidgets('it names the rule and the stop, in words', (tester) async {
      await pump(tester, reachedIndex: 2);
      expect(find.text('Wake me up'), findsOneWidget);
      expect(find.text('2 stations before Kalyan'), findsOneWidget);
    });

    testWidgets('the other rule reads differently, so it cannot drift', (
      tester,
    ) async {
      await pump(tester, reachedIndex: 2, choice: WakeChoice.onlyDestination);
      expect(find.text('at Kalyan'), findsOneWidget);
      expect(find.text('2 stations before Kalyan'), findsNothing);
    });

    testWidgets('NO TAPPABLE SEGMENTS SURVIVE', (tester) async {
      await pump(tester, reachedIndex: 2);
      expect(find.byKey(const Key('wake_last_two')), findsNothing);
      expect(find.byKey(const Key('wake_only_destination')), findsNothing);
    });
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
          wakeEnabled: true,
          onWakeEnabled: _ignore,
          crowdMode: false,
          pulseIntervalSeconds: 180,
          onCrowdMode: _ignore,
          journey: longest,
          reachedIndex: 2,
          wakeChoice: WakeChoice.lastTwoStations,
          onEndJourney: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(find.text('Wake me up'));
    expect(label.maxLines, 1);
    expect(find.byKey(const Key('end_journey')), findsOneWidget);
  });

  group("THE RIDER'S WAKE TOGGLE, on the shield pill", () {
    testWidgets('the pill says which state it is in, both ways', (tester) async {
      await pump(tester, reachedIndex: 1);
      expect(find.text('Wake-up on'), findsOneWidget);

      await pump(tester, reachedIndex: 1, wakeEnabled: false);
      expect(find.text('Wake-up off'), findsOneWidget);
    });

    testWidgets('THE PILL IS THE CONTROL, which it only looked like before', (
      tester,
    ) async {
      // It was shaped like a toggle and was a statement, which is the same lie
      // as the wake control deleted on 11 Aug with the sign reversed.
      final taps = <bool>[];
      await pump(tester, reachedIndex: 1, wakeTaps: taps);

      await tester.tap(find.byKey(const Key('wake_toggle')));
      await tester.pumpAndSettle();

      expect(taps, [false], reason: 'an armed alarm turns off');
    });

    testWidgets('THE ROW AGREES WITH THE PILL, or the screen contradicts itself', (
      tester,
    ) async {
      // The first build on the device showed "Wake-up off" directly above
      // "Wake me up, 2 stations before Kalyan", in the two places a rider looks
      // before pocketing the phone.
      await pump(tester, reachedIndex: 1, wakeEnabled: false);

      expect(find.text('2 stations before Kalyan'), findsNothing);
      expect(
        find.text('Off for this journey. Stations are still announced.'),
        findsOneWidget,
        reason: 'and it must say what SURVIVES, not only what stopped',
      );
    });

    testWidgets('it clears the 48 dp floor like every other target', (
      tester,
    ) async {
      await pump(tester, reachedIndex: 1);

      final size = tester.getSize(find.byKey(const Key('wake_toggle')));
      expect(size.height, greaterThanOrEqualTo(48.0));
    });
  });

  group('CROWD MODE, moved onto this screen 12 Aug 2026', () {
    // It is a decision about the train the rider is standing in, not about
    // their setup: you find out the carriage is packed when the doors open,
    // which is long after you last looked at Settings. Screen 1 was rejected
    // for it, because you have not boarded yet.

    testWidgets('the row states the cadence in force, crowd mode folded in', (
      tester,
    ) async {
      await pump(tester, reachedIndex: 1, pulseIntervalSeconds: 180);
      expect(find.text('Every 3 minutes'), findsOneWidget);

      // 45 s is crowd mode's cadence, and it is said in SECONDS. "0.75
      // minutes" is nobody's idea of a packed train.
      await pump(
        tester,
        reachedIndex: 1,
        crowdMode: true,
        pulseIntervalSeconds: 45,
      );
      expect(find.text('Every 45 seconds'), findsOneWidget);
    });

    testWidgets('a pulse switched off says so rather than going blank', (
      tester,
    ) async {
      // Null is a state the rider chose, not a missing value.
      await pump(tester, reachedIndex: 1, pulseIntervalSeconds: null);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('THE WHOLE ROW IS THE TARGET, not just the switch', (
      tester,
    ) async {
      // A rider aims a thumb at this on a moving train. The switch alone is
      // about 40 px wide, under the 48 dp floor this project measures against.
      final taps = <bool>[];
      await pump(tester, reachedIndex: 1, crowdTaps: taps);

      await tester.tap(find.text('Pocket Pulse'));
      await tester.pumpAndSettle();

      expect(taps, [true], reason: 'tapping the label must toggle it on');
    });

    testWidgets('the switch reports the value it would move to', (
      tester,
    ) async {
      final taps = <bool>[];
      await pump(
        tester,
        reachedIndex: 1,
        crowdMode: true,
        pulseIntervalSeconds: 45,
        crowdTaps: taps,
      );

      await tester.tap(find.byType(PulseSwitch));
      await tester.pumpAndSettle();

      expect(taps, [false], reason: 'an on control turns it off');
    });

    testWidgets('the wake line is still a statement, with no control', (
      tester,
    ) async {
      // Row one states, row two offers. What will happen, so the rider can
      // pocket the phone; the pre-warning DISTANCE stays a Guardian Plus
      // surface and must not become a second way to change leadTimeS.
      await pump(tester, reachedIndex: 1);

      expect(find.text('Wake me up'), findsOneWidget);
      expect(
        find.byType(PulseSwitch),
        findsOneWidget,
        reason: 'exactly one control on this card, and it is the pulse',
      );
    });
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
          wakeEnabled: true,
          onWakeEnabled: _ignore,
          crowdMode: false,
          pulseIntervalSeconds: 180,
          onCrowdMode: _ignore,
          journey: longest,
          reachedIndex: 1,
          wakeChoice: WakeChoice.onlyDestination,
          onEndJourney: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('the shield says the app is watching, on one line', (
    tester,
  ) async {
    // A PILL since 11 Aug 2026, matching Screen 1's status chip. It was a bare
    // icon beside a hard-wrapped two-line label, which is why the icon looked
    // misaligned: a 22 px glyph centred against two lines sits level with the
    // gap between them. The copy shortened to fit one line, because a pill that
    // wraps is not a pill.
    await pump(tester, reachedIndex: 2);
    expect(find.text('Wake-up on'), findsOneWidget);
    final label = tester.widget<Text>(find.text('Wake-up on'));
    expect(
      label.maxLines,
      1,
      reason: 'the badge gives way by ellipsis, not by wrapping',
    );
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

/// These two fixtures build the screen directly to test chain layout, and do
/// not press the crowd-mode control. The tests that do press it pass their own
/// collector through `pump`.
void _ignore(bool _) {}
