import 'package:commute_guardian/widgets/pulse_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 4's crowd-mode control, rebuilt 12 Aug 2026 against Apple's
/// fluid-interface rules after Material's Switch shipped for a few hours.
///
/// The four failings it replaces are behaviours, not looks, which is why they
/// are tested rather than eyeballed: no feedback on touch-down, a fixed
/// duration instead of a spring, no way to grab it mid-flight, and no haptic on
/// the frame the value commits.
void main() {
  Future<(List<bool> changes, Widget widget)> build({bool value = false}) async {
    final changes = <bool>[];
    return (
      changes,
      StatefulBuilder(
        builder: (context, setState) => PulseSwitch(
          value: value,
          onChanged: (next) {
            changes.add(next);
            setState(() => value = next);
          },
        ),
      ),
    );
  }

  Future<List<bool>> pump(WidgetTester tester, {bool value = false}) async {
    final (changes, widget) = await build(value: value);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: widget))),
    );
    return changes;
  }

  group('RESPONSE, which is the foundation the rest sits on', () {
    testWidgets('it answers on touch DOWN, not on release', (tester) async {
      await pump(tester);

      final paint = find.descendant(
        of: find.byType(PulseSwitch),
        matching: find.byType(CustomPaint),
      );
      final before = tester.widget<CustomPaint>(paint).painter;

      final press = await tester.startGesture(
        tester.getCenter(find.byType(PulseSwitch)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        identical(tester.widget<CustomPaint>(paint).painter, before),
        isFalse,
        reason: 'the thumb must take the weight of the finger immediately; '
            'feedback that waits for release reads as lag',
      );

      await press.up();
      await tester.pumpAndSettle();
    });
  });

  group('COMMIT, and what the rider feels when it happens', () {
    testWidgets('a tap toggles once and reports the new value', (tester) async {
      final changes = await pump(tester);

      await tester.tap(find.byType(PulseSwitch));
      await tester.pumpAndSettle();

      expect(changes, [true]);
    });

    testWidgets('THE HAPTIC LANDS WITH THE COMMIT, and it is a selection tick', (
      tester,
    ) async {
      // Causality and harmony: the touch answers the thing the rider just did.
      // And it must be `selectionClick`, never a vibration pattern: this app's
      // own buzzes MEAN things (one tap is Pocket Pulse, an insistent burst is
      // the wake alarm) and a control may not speak that vocabulary.
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add('${call.arguments}');
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

      await pump(tester);
      await tester.tap(find.byType(PulseSwitch));
      await tester.pumpAndSettle();

      expect(calls, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('a press that slides away and lifts commits nothing', (
      tester,
    ) async {
      final changes = await pump(tester);

      final press = await tester.startGesture(
        tester.getCenter(find.byType(PulseSwitch)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      // Far enough to be a cancel rather than a drag of the thumb.
      await press.moveBy(const Offset(0, 220));
      await press.up();
      await tester.pumpAndSettle();

      expect(changes, isEmpty, reason: 'a slip must be forgivable');
    });
  });

  group('DIRECT MANIPULATION', () {
    testWidgets('THE SIGN OF THE FLICK DECIDES, not where the thumb sits', (
      tester,
    ) async {
      // A rider who flicks left from the right-hand side means "off", even
      // though at the instant they let go the thumb is still nearer "on".
      final changes = await pump(tester, value: true);

      // FLICKED BY HAND, with timed moves. `tester.fling` reports a release
      // velocity of exactly 0.0 against this widget, so the first version of
      // this test asserted a flick while delivering a slow drag, and the widget
      // was right to leave the value alone. 8 px every 8 ms is 1000 px/s.
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(PulseSwitch)),
      );
      for (var i = 0; i < 4; i++) {
        await drag.moveBy(
          const Offset(-8, 0),
          timeStamp: Duration(milliseconds: 8 * (i + 1)),
        );
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(changes, [false]);
    });

    testWidgets('a drag most of the way across carries it over', (
      tester,
    ) async {
      final changes = await pump(tester);

      // MOVED IN STEPS, the way a finger does. A single large moveBy is
      // swallowed by the recognizer as the drag START and produces no update
      // at all, which is what made the first version of this test fail against
      // correct code.
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(PulseSwitch)),
      );
      for (var i = 0; i < 6; i++) {
        await drag.moveBy(const Offset(6, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(changes, [true]);
    });

    testWidgets('a drag that goes and comes back commits nothing', (
      tester,
    ) async {
      final changes = await pump(tester);

      final drag = await tester.startGesture(
        tester.getCenter(find.byType(PulseSwitch)),
      );
      for (var i = 0; i < 5; i++) {
        await drag.moveBy(const Offset(5, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (var i = 0; i < 5; i++) {
        await drag.moveBy(const Offset(-5, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(changes, isEmpty);
    });
  });

  group('REDUCED MOTION takes the travel, never the control', () {
    testWidgets('it still toggles with animations disabled', (tester) async {
      final changes = <bool>[];
      var value = false;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) => PulseSwitch(
                    value: value,
                    onChanged: (next) {
                      changes.add(next);
                      setState(() => value = next);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(PulseSwitch));
      await tester.pumpAndSettle();

      // The gesture is not decoration and must survive. Only the travel goes.
      expect(changes, [true]);
    });
  });

  testWidgets('the target clears the 48 dp floor', (tester) async {
    // Measured, never inferred, per this project's button-sizing rule. A rider
    // aims at this with a thumb on a moving train.
    await pump(tester);

    final size = tester.getSize(find.byType(PulseSwitch));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
  });
}
