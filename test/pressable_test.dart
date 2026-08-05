import 'package:commute_guardian/widgets/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Press feedback. Until 29 Jul 2026 every tappable surface on Screens 1 and 2
/// was a bare GestureDetector, so a tap produced nothing visible until the next
/// screen arrived.
void main() {
  double currentScale(WidgetTester tester) =>
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

  Future<void> pumpPressable(
    WidgetTester tester, {
    required VoidCallback onTap,
    bool reducedMotion = false,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Pressable(
              onTap: onTap,
              child: const SizedBox(width: 200, height: 60),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a held surface scales down, and lets go when released', (
    tester,
  ) async {
    var taps = 0;
    await pumpPressable(tester, onTap: () => taps++);

    expect(currentScale(tester), 1.0, reason: 'at rest');

    final press = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    // Past kPressTimeout: the tap recogniser does not report onTapDown until
    // it has held the gesture long enough to know it is not a scroll.
    await tester.pump(const Duration(milliseconds: 150));
    expect(currentScale(tester), lessThan(1.0), reason: 'while held');

    await press.up();
    await tester.pumpAndSettle();
    expect(currentScale(tester), 1.0, reason: 'after release');
    expect(taps, 1);
  });

  testWidgets('a cancelled press lets go without firing the action', (
    tester,
  ) async {
    // A rider who presses a destination card and slides their thumb off has
    // changed their mind. The surface must return and the journey must not
    // start.
    var taps = 0;
    await pumpPressable(tester, onTap: () => taps++);

    final press = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(currentScale(tester), lessThan(1.0));

    await press.moveBy(const Offset(0, 400));
    await press.up();
    await tester.pumpAndSettle();

    expect(currentScale(tester), 1.0);
    expect(taps, 0, reason: 'sliding off cancels the tap');
  });

  testWidgets('reduced motion takes the scale, never the tap', (tester) async {
    // A scale is movement, which is the category that causes motion sickness.
    // The gesture is not decoration and must survive.
    var taps = 0;
    await pumpPressable(tester, onTap: () => taps++, reducedMotion: true);

    final press = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      currentScale(tester),
      1.0,
      reason: 'no movement under reduced motion',
    );

    await press.up();
    await tester.pumpAndSettle();
    expect(taps, 1, reason: 'the tap still works');
  });

  testWidgets('a row tints while held and clears when released', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: PressableRow(
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 44),
          ),
        ),
      ),
    );

    double tintAlpha() {
      final box = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      return ((box.decoration! as BoxDecoration).color!).a;
    }

    expect(tintAlpha(), 0.0, reason: 'at rest');

    final press = await tester.startGesture(
      tester.getCenter(find.byType(PressableRow)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(tintAlpha(), greaterThan(0.0), reason: 'while held');

    await press.up();
    await tester.pumpAndSettle();
    expect(tintAlpha(), 0.0, reason: 'after release');
    expect(taps, 1);
  });
}
