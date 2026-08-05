import 'package:commute_guardian/screens/arrival_screen.dart';
import 'package:commute_guardian/services/wind_down.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 5, Arrival.
///
/// The tests that matter here are about the state the FRAME DOES NOT DRAW: the
/// rider has arrived and nothing is counting yet, because WindDown only starts
/// its countdown once they have provably walked 150 m from where the train
/// stopped. On the 18 Jul Kalyan log that was about six minutes.
void main() {
  /// A clock the test drives, so pumping forward actually moves the countdown.
  /// The screen takes its `now` as a parameter for the same reason every engine
  /// in this project does.
  late DateTime now;

  setUp(() => now = DateTime(2026, 7, 30, 19, 52));

  Future<(List<int> endNows, List<String> saves)> pumpArrival(
    WidgetTester tester, {
    Duration? countdown,
    Duration window = WindDown.countdown,
    bool offerSave = true,
    VoidCallback? onExtend,
  }) async {
    final endNows = <int>[];
    final saves = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArrivalScreen(
          destinationName: 'Kalyan',
          summaryLine: '52 min • 18 stations • Dadar → Kalyan',
          autoEndAt: countdown == null ? null : now.add(countdown),
          window: window,
          clock: () => now,
          onEndNow: () => endNows.add(1),
          onExtend: onExtend,
          onSaveRoute: offerSave ? saves.add : null,
        ),
      ),
    );
    await tester.pump();
    return (endNows, saves);
  }

  testWidgets('the arrived state promises no time it cannot keep', (
    tester,
  ) async {
    // THE STATE THE FRAME NEVER DREW, and the one a rider sees first and
    // longest. No countdown is running, so there must be no clock, and above
    // all no "auto end" promise with a number attached to it.
    await pumpArrival(tester);

    expect(find.text("You've arrived at Kalyan"), findsOneWidget);
    expect(find.text('auto end'), findsNothing);
    expect(
      find.text('Travel Mode stays on until you leave the station.'),
      findsOneWidget,
    );
  });

  testWidgets('EXTEND IS ABSENT WHEN THERE IS NOTHING TO EXTEND', (
    tester,
  ) async {
    // WindDown.extend() early-returns unless the countdown is running, so an
    // Extend button in this state would be a control that does nothing when
    // pressed. Absent beats disabled: there is no countdown to speak of yet,
    // so the button has nothing to be disabled ABOUT.
    await pumpArrival(tester);
    expect(find.text('Extend 10 min'), findsNothing);
    expect(find.text('End now'), findsOneWidget);
  });

  testWidgets('the counting state shows the clock and both ways out', (
    tester,
  ) async {
    await pumpArrival(
      tester,
      countdown: const Duration(seconds: 39),
      onExtend: () {},
    );

    expect(find.text('0:39'), findsOneWidget);
    expect(find.text('auto end'), findsOneWidget);
    expect(find.text('End now'), findsOneWidget);
    expect(find.text('Extend 10 min'), findsOneWidget);
  });

  testWidgets('the clock counts down', (tester) async {
    await pumpArrival(
      tester,
      countdown: const Duration(seconds: 39),
      onExtend: () {},
    );
    expect(find.text('0:39'), findsOneWidget);

    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0:39'), findsNothing);
    expect(find.text('0:36'), findsOneWidget);

    // Settle the ring's one-second tween so the test does not end mid-frame.
    await tester.pumpAndSettle();
  });

  testWidgets('an extended countdown reads in minutes, not a stuck hour', (
    tester,
  ) async {
    // WindDown.extension is ten minutes, and it REPLACES the deadline rather
    // than adding to it. The label has to survive a two-digit minute count.
    await pumpArrival(
      tester,
      countdown: WindDown.extension,
      window: WindDown.extension,
      onExtend: () {},
    );
    expect(find.text('10:00'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the save prompt collects the label SavedRoute needs', (
    tester,
  ) async {
    // Homeless since 16 Jul, when the save star came off the Screen 2 rows.
    // Journey end is where it belongs: the route has proven real, and this is
    // the only moment a rider can sensibly be asked to NAME it.
    final (_, saves) = await pumpArrival(tester);

    expect(find.text('Save this route?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_route_home')));
    await tester.pump();

    expect(saves, ['Home']);
  });

  testWidgets('"Not now" takes the prompt away and leaves the ride alone', (
    tester,
  ) async {
    final (endNows, saves) = await pumpArrival(tester);

    await tester.tap(find.byKey(const Key('save_route_not_now')));
    await tester.pumpAndSettle();

    expect(find.text('Save this route?'), findsNothing);
    expect(saves, isEmpty);
    // Declining to save must not end anything.
    expect(endNows, isEmpty);
    expect(find.text('End now'), findsOneWidget);
  });

  testWidgets('THE TAP ON HOME CHANGES SOMETHING, and says what', (
    tester,
  ) async {
    // A card that sits there with both buttons still offered reads as a press
    // that did not land, and this rider is walking down a platform rather than
    // watching for a database write. The confirmation names the label back,
    // because "Saved" alone tells them nothing they can act on later.
    final (_, saves) = await pumpArrival(tester);

    await tester.tap(find.byKey(const Key('save_route_home')));
    await tester.pumpAndSettle();

    expect(saves, ['Home']);
    expect(find.text('Save this route?'), findsNothing);
    expect(
      find.text('Saved as Home. One tap from home next time.'),
      findsOneWidget,
    );
    // The way out of the screen is untouched by any of it.
    expect(find.text('End now'), findsOneWidget);
  });

  testWidgets('a route already saved is not asked about again', (tester) async {
    await pumpArrival(tester, offerSave: false);
    expect(find.text('Save this route?'), findsNothing);
  });

  testWidgets('End now reports the press exactly once', (tester) async {
    // NO HOLD TO CONFIRM here, unlike Screen 4. That gesture guards a rider
    // asleep with the phone in a pocket; this rider has arrived and is holding
    // it. The test pins the plain tap so nobody "improves" it into a hold.
    final (endNows, _) = await pumpArrival(tester);

    await tester.tap(find.byKey(const Key('arrival_end_now')));
    await tester.pump();

    expect(endNows, [1]);
  });
}
