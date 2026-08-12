import 'dart:io';

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

  test('NO MATERIAL BUTTON ANYWHERE IN THE APP', () {
    // Punchlist item 11, closed 12 Aug 2026, and it found MORE than the
    // punchlist knew about: the item said "one TextButton still takes
    // Material's ripple" (the onboarding skip) and there were two. The second
    // was the "Got it" button on Screen 1's chip tip banner, which appears
    // only when a rider is already having trouble finding their location.
    //
    // Two instances of a thing an eye had already been over is the argument
    // for a guard rather than a fix. A ripple reads as stock Android in a
    // custom dark glass design, and it is exactly the sort of detail that
    // comes back in one hurried evening.
    // THE DEBUG SCREEN IS EXEMPT, and only it. `RideDebugScreen` lives in
    // main.dart and is a bench instrument behind a long press on Settings'
    // version line: no rider reaches it, every bench in this project runs
    // through it, and its ElevatedButtons and OutlinedButtons are correct
    // there because looking like stock Android is what a debug control should
    // look like. So main.dart is allowed those two and no others: the ripple
    // item was about flat and text-shaped surfaces, and the "Got it" banner in
    // that same file was a rider-facing one.
    const debugOnly = {'ElevatedButton', 'OutlinedButton'};

    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final isMain = file.path.endsWith('main.dart');
      // Comments stripped FIRST. This test's own kind of guard has been
      // repaired five times in this project for matching text that merely
      // looked like the thing, and the fixes committed today put the word
      // "TextButton" into three comments explaining why it is gone.
      final code = file
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final widget in const [
        'TextButton',
        'ElevatedButton',
        'OutlinedButton',
        'InkWell',
        'FilledButton',
      ]) {
        // A word boundary, so `TextButtonTheme` in a ThemeData (which sets
        // defaults and creates no ripple) is not read as a button.
        if (isMain && debugOnly.contains(widget)) continue;
        if (RegExp('\\b$widget\\s*\\(').hasMatch(code)) {
          offenders.add('${file.path}: $widget');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'every tap in this app goes through Pressable or PressableRow',
    );
  });
}
