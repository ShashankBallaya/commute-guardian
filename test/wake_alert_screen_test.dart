import 'package:commute_guardian/screens/wake_alert_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wake alert. The screen the whole product exists to put in front of a
/// sleeping rider, so the tests here are mostly about what it must NOT say.
void main() {
  Future<List<int>> pumpAlert(
    WidgetTester tester, {
    String? lastPassedLine = 'Thakurli passed 19:49',
    bool climbing = true,
  }) async {
    final acks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: WakeAlertScreen(
          destinationName: 'Kalyan',
          lastPassedLine: lastPassedLine,
          climbing: climbing,
          onAcknowledge: () => acks.add(1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return acks;
  }

  testWidgets('it says what to do and which stop it is for', (tester) async {
    await pumpAlert(tester);
    expect(find.text('Wake up\nKalyan is next'), findsOneWidget);
    expect(find.text('Thakurli passed 19:49'), findsOneWidget);
  });

  testWidgets('THE LADDER IS NEVER GIVEN A TOTAL', (tester) async {
    // The frame read "rung 2 of 4". rungVolumes is [0.3, 0.6, 1.0], three
    // steps, and the rung counter keeps climbing past the end while the volume
    // holds at full: the ladder ends on an ACKNOWLEDGEMENT or on the ceiling
    // station, never on a count. Telling a half-asleep rider it stops after
    // four is the exact failure this app exists to prevent.
    await pumpAlert(tester);
    expect(find.textContaining('of 4'), findsNothing);
    expect(find.textContaining('rung'), findsNothing);
    expect(find.text('Getting louder until you answer'), findsOneWidget);
  });

  testWidgets('at full volume it still promises to keep going', (tester) async {
    await pumpAlert(tester, climbing: false);
    expect(
      find.text('This will keep sounding until you answer'),
      findsOneWidget,
    );
    expect(find.textContaining('of 4'), findsNothing);
  });

  testWidgets('no dash punctuation, per the project copy rule', (tester) async {
    // The frame's status line used an en dash.
    await pumpAlert(tester);
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      final s = w.data ?? w.textSpan?.toPlainText() ?? '';
      expect(s.contains('–'), isFalse, reason: 'en dash in "$s"');
      expect(s.contains('—'), isFalse, reason: 'em dash in "$s"');
    }
  });

  testWidgets('one tap acknowledges: no hold, no slide', (tester) async {
    // The opposite of End journey on purpose. A rider fighting their way out of
    // sleep must not have to be dexterous, and acking early is cheap: the ride
    // carries on and the destination alarm still comes.
    final acks = await pumpAlert(tester);
    await tester.tap(find.byKey(const Key('wake_ack')));
    await tester.pumpAndSettle();
    expect(acks, hasLength(1));
  });

  testWidgets('the button is louder than the earphone hint', (tester) async {
    // On iOS in a ducked session the earphone tap goes to the music app, not to
    // us. The button is the affordance that always works, so it must never be
    // the quieter of the two.
    await pumpAlert(tester);

    final button = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('wake_ack')),
        matching: find.byType(Text),
      ),
    );
    final hint = tester.widget<Text>(
      find.text('or press play/pause on your earphones'),
    );
    expect(button.style!.fontSize!, greaterThan(hint.style!.fontSize!));
    expect(button.style!.fontWeight, FontWeight.w700);
  });

  testWidgets('the glow escalates with the ladder, without naming a total', (
    tester,
  ) async {
    // A rider who surfaces mid-ladder should be able to SEE it has been going a
    // while. This is the honest version of "rung 2 of 4": it conveys duration
    // without promising an end.
    double glowFor(int rung) {
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      return ((container.decoration! as BoxDecoration).boxShadow!.first.color)
          .a;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: WakeAlertScreen(
          destinationName: 'Kalyan',
          rung: 1,
          onAcknowledge: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = glowFor(1);

    await tester.pumpWidget(
      MaterialApp(
        home: WakeAlertScreen(
          destinationName: 'Kalyan',
          rung: 3,
          onAcknowledge: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(glowFor(3), greaterThan(first));
  });

  testWidgets('the ack target is big enough to hit without aiming', (
    tester,
  ) async {
    // Hunted for by a fumbling thumb, in the dark, on a moving train.
    await pumpAlert(tester);
    final size = tester.getSize(find.byKey(const Key('wake_ack')));
    expect(size.height, greaterThan(80));
  });

  testWidgets('BACK CANNOT DISMISS THE ALERT WHILE THE LADDER IS LIVE', (
    tester,
  ) async {
    // Backing out would not stop the alarm: the ladder runs in the service and
    // keeps climbing. A back press would leave the rider with a phone still
    // escalating and the only working ack button gone from the screen.
    final acks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => WakeAlertScreen(
                  destinationName: 'Kalyan',
                  onAcknowledge: () => acks.add(1),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(WakeAlertScreen), findsOneWidget);

    // The system back gesture.
    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.byType(WakeAlertScreen),
      findsOneWidget,
      reason: 'the alert must still be on screen',
    );
    expect(
      popped,
      isTrue,
      reason: 'the route consumed the back, it did not fall through',
    );
    expect(
      acks,
      isEmpty,
      reason: 'back is never an acknowledgement: it must not silence an alarm',
    );
  });

  testWidgets('nothing passed yet simply omits the line', (tester) async {
    await pumpAlert(tester, lastPassedLine: null);
    expect(find.textContaining('passed'), findsNothing);
    expect(find.text('Wake up\nKalyan is next'), findsOneWidget);
  });
}
