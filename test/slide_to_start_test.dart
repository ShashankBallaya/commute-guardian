import 'package:commute_guardian/widgets/slide_to_start.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Slide to start. The mirror of hold-to-end: both ends of a ride are
/// deliberate gestures, and deliberately different ones.
void main() {
  Future<List<int>> pumpSlider(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    final starts = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: SlideToStart(
                label: 'Slide to start',
                enabled: enabled,
                onStart: () => starts.add(1),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return starts;
  }

  testWidgets('a tap does nothing at all', (tester) async {
    // The whole point of replacing the button: starting a ride should take a
    // gesture, not a brush against a phone in a hand on a crowded train.
    final starts = await pumpSlider(tester);
    await tester.tap(find.byKey(const Key('slide_to_start')));
    await tester.pumpAndSettle();
    expect(starts, isEmpty);
  });

  testWidgets('a short slow drag snaps back and starts nothing', (
    tester,
  ) async {
    final starts = await pumpSlider(tester);

    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byKey(const Key('slide_to_start'))) +
          const Offset(30, 34),
    );
    // Slowly, a third of the way.
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(starts, isEmpty);
  });

  testWidgets('a slow drag across the track starts the ride', (tester) async {
    final starts = await pumpSlider(tester);

    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byKey(const Key('slide_to_start'))) +
          const Offset(30, 34),
    );
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(starts, hasLength(1));
  });

  testWidgets('a confident flick past a third counts, without the full track', (
    tester,
  ) async {
    // Requiring the whole distance is the common way to get this wrong: it
    // makes a confident gesture feel like work.
    final starts = await pumpSlider(tester);
    await tester.fling(
      find.byKey(const Key('slide_to_start')),
      const Offset(160, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(starts, hasLength(1));
  });

  testWidgets('a flick that starts too near the left edge does not', (
    tester,
  ) async {
    // Speed alone must never start a ride: a stray brush is fast too.
    final starts = await pumpSlider(tester);
    await tester.fling(
      find.byKey(const Key('slide_to_start')),
      const Offset(40, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(starts, isEmpty);
  });

  testWidgets('a disabled track does not move, so it reads as unavailable', (
    tester,
  ) async {
    final starts = await pumpSlider(tester, enabled: false);
    await tester.fling(
      find.byKey(const Key('slide_to_start')),
      const Offset(300, 0),
      2000,
    );
    await tester.pumpAndSettle();
    expect(starts, isEmpty);
  });
}
