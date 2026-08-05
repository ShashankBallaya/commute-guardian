import 'package:commute_guardian/screens/preparing_screen.dart';
import 'package:commute_guardian/theme/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 3, Preparing. State A (waiting for a fix), frame approved 29 Jul 2026.
void main() {
  const stateASteps = [
    PrepStep(
      label: 'Finding you',
      detail: 'This can take a few seconds indoors',
      status: PrepStatus.active,
    ),
    PrepStep(label: 'Watching for your stop', status: PrepStatus.pending),
    PrepStep(
      label: 'Direction',
      detail: 'Confirmed once the train moves',
      status: PrepStatus.pending,
    ),
  ];

  Future<int> pumpPreparing(
    WidgetTester tester, {
    List<PrepStep> steps = stateASteps,
  }) async {
    var cancels = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PreparingScreen(
          originName: 'Shahad',
          destinationName: 'Kalyan',
          steps: steps,
          onCancel: () => cancels++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cancels;
  }

  testWidgets('the contract is stated before anything else', (tester) async {
    await pumpPreparing(tester);

    // The last chance to catch a wrong pick, which matters when Kalyan and
    // Kalwa are one fat-finger apart in the picker.
    expect(find.textContaining('Shahad', findRichText: true), findsOneWidget);
    expect(find.text("We'll wake you up before Kalyan."), findsOneWidget);
  });

  testWidgets('state A shows one thing working and the rest waiting', (
    tester,
  ) async {
    await pumpPreparing(tester);

    expect(find.text('Getting ready'), findsOneWidget);
    expect(find.text('Finding you'), findsOneWidget);
    expect(find.text('This can take a few seconds indoors'), findsOneWidget);
    expect(find.text('Watching for your stop'), findsOneWidget);
  });

  testWidgets('direction is never a pending step that can complete here', (
    tester,
  ) async {
    // It cannot resolve until the train has crossed a station, so the screen
    // says when it will happen rather than pretending to wait for it.
    await pumpPreparing(tester);
    expect(find.text('Confirmed once the train moves'), findsOneWidget);
  });

  testWidgets('the ring reports real steps, not a spun animation', (
    tester,
  ) async {
    // State A: one step in flight, nothing finished. The arc must still DRAW.
    // Counting only finished steps passed this test at 0.0 and was wrong on a
    // real phone: the ring was empty under "Getting ready", which reads as
    // nothing happening. A step in flight is half earned.
    await pumpPreparing(tester);
    var ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, closeTo(0.5 / 3, 0.001));
    expect(
      ring.value,
      greaterThan(0.0),
      reason: 'an empty ring reads as a screen that has not started',
    );

    // Two of three done.
    await pumpPreparing(
      tester,
      steps: const [
        PrepStep(label: 'Finding you', status: PrepStatus.done),
        PrepStep(label: 'Watching for your stop', status: PrepStatus.done),
        PrepStep(label: 'Direction', status: PrepStatus.pending),
      ],
    );
    ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, closeTo(2 / 3, 0.001));
    expect(
      ring.value,
      isNot(isNull),
      reason:
          'a null value is an indeterminate spinner, which would be theatre',
    );
  });

  testWidgets('a working step is amber and a waiting one is dim', (
    tester,
  ) async {
    await pumpPreparing(tester);

    Color dotColourNear(String label) {
      final row = find
          .ancestor(of: find.text(label), matching: find.byType(Row))
          .first;
      final box = tester.widget<Container>(
        find.descendant(of: row, matching: find.byType(Container)).first,
      );
      return ((box.decoration! as BoxDecoration).color!);
    }

    expect(dotColourNear('Finding you'), Palette.dotAmber);
    expect(dotColourNear('Watching for your stop'), isNot(Palette.dotAmber));
  });

  group('state B, the fix did not land', () {
    Future<({List<String> taps, WidgetTester t})> pumpB(
      WidgetTester tester,
    ) async {
      final taps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CannotLocateScreen(
            originName: 'Shahad',
            destinationName: 'Kalyan',
            onRetry: () => taps.add('retry'),
            onSetStation: () => taps.add('set'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (taps: taps, t: tester);
    }

    testWidgets('says what to do, not what went wrong', (tester) async {
      await pumpB(tester);
      expect(find.text("We can't find you yet"), findsOneWidget);
      // The approved frame read "GPS is sow under a station roof".
      expect(
        find.textContaining('GPS is slow under a station roof'),
        findsOneWidget,
      );
      expect(find.textContaining('sow'), findsNothing);
    });

    testWidgets('no ring: nothing progresses until the rider acts', (
      tester,
    ) async {
      await pumpB(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('both ways forward work, and neither is a dead end', (
      tester,
    ) async {
      final r = await pumpB(tester);

      await tester.tap(find.byKey(const Key('cannot_locate_retry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cannot_locate_set_station')));
      await tester.pumpAndSettle();

      expect(r.taps, ['retry', 'set']);
      // Single-spaced. The frame had "Set  my station".
      expect(find.text('Set my station'), findsOneWidget);
    });

    testWidgets('the contract survives the failure', (tester) async {
      // The rider still needs to know what they picked, especially here: a
      // failed fix is the moment they are most likely to back out.
      await pumpB(tester);
      expect(find.text("We'll wake you up before Kalyan."), findsOneWidget);
    });
  });

  group('state C, background location refused', () {
    Future<List<String>> pumpC(WidgetTester tester) async {
      final taps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: BackgroundLocationScreen(
            originName: 'Shahad',
            destinationName: 'Kalyan',
            onOpenSettings: () => taps.add('settings'),
            onStartAnyway: () => taps.add('anyway'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return taps;
    }

    testWidgets('the consequence is the headline, not the permission name', (
      tester,
    ) async {
      // A rider does not care what the setting is called. They care that they
      // will sleep past their stop.
      await pumpC(tester);
      expect(
        find.text("We can't wake you with the screen off"),
        findsOneWidget,
      );
    });

    testWidgets('the setting names appear as instructions in the body', (
      tester,
    ) async {
      await pumpC(tester);
      expect(
        find.textContaining('While using the app', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Allow all the time', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('start anyway exists, because a degraded ride beats none', (
      tester,
    ) async {
      final taps = await pumpC(tester);
      await tester.tap(
        find.byKey(const Key('background_location_start_anyway')),
      );
      await tester.pumpAndSettle();
      expect(taps, ['anyway']);
    });

    testWidgets('start anyway is quieter than the fix', (tester) async {
      // Available, never encouraged. If these two ever render alike, the screen
      // is nudging riders toward the choice it exists to discourage.
      await pumpC(tester);

      final fix = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('background_location_settings')),
          matching: find.byType(Text),
        ),
      );
      final anyway = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('background_location_start_anyway')),
          matching: find.byType(Text),
        ),
      );
      expect(fix.style!.color, Palette.ground, reason: 'dark on a white fill');
      expect(anyway.style!.color!.a, lessThan(1.0), reason: 'dimmed, no fill');
    });
  });

  group('state D, something will make the ride worse', () {
    const earphones = PrepStep(
      label: "Your earphones aren't connected",
      detail: 'The alarm will play out loud',
      status: PrepStatus.active,
    );
    const volume = PrepStep(
      label: 'Volume is low',
      detail: 'Turn it up so you hear us over the train',
      status: PrepStatus.active,
    );
    const watching = PrepStep(
      label: 'Watching for Kalyan',
      status: PrepStatus.done,
    );

    Future<List<String>> pumpD(
      WidgetTester tester,
      List<PrepStep> steps,
    ) async {
      final taps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PreflightScreen(
            originName: 'Shahad',
            destinationName: 'Kalyan',
            steps: steps,
            onStart: () => taps.add('start'),
            onRecheck: () => taps.add('recheck'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return taps;
    }

    testWidgets('the headline counts the warnings, it is never hardcoded', (
      tester,
    ) async {
      // The frame said "Two things" because it drew two. One warning alone must
      // not say "Two".
      await pumpD(tester, const [earphones, volume, watching]);
      expect(find.text('Two things before you doze off'), findsOneWidget);

      await pumpD(tester, const [earphones, watching]);
      expect(find.text('One thing before you doze off'), findsOneWidget);
      expect(find.textContaining('Two things'), findsNothing);
    });

    testWidgets('the green row is not counted as a problem', (tester) async {
      // "Watching for Kalyan" is reassurance, not a warning.
      await pumpD(tester, const [earphones, watching]);
      expect(find.text('One thing before you doze off'), findsOneWidget);
    });

    testWidgets('the two warnings are distinct, not the same line twice', (
      tester,
    ) async {
      // The approved frame repeated "Your earphones aren't connected" over the
      // volume sub-line.
      await pumpD(tester, const [earphones, volume, watching]);
      expect(find.text("Your earphones aren't connected"), findsOneWidget);
      expect(find.text('Volume is low'), findsOneWidget);
      expect(
        find.text('Turn it up so you hear us over the train'),
        findsOneWidget,
      );
    });

    testWidgets('it never blocks: the ride can always start', (tester) async {
      final taps = await pumpD(tester, const [earphones, volume, watching]);
      await tester.tap(find.byKey(const Key('preflight_start')));
      await tester.pumpAndSettle();
      expect(taps, ['start']);
    });

    testWidgets('a re-check is offered so nobody has to guess', (tester) async {
      final taps = await pumpD(tester, const [earphones, watching]);
      await tester.tap(find.byKey(const Key('preflight_recheck')));
      await tester.pumpAndSettle();
      expect(taps, ['recheck']);
    });
  });

  testWidgets('there is a way out, because a fix can hang', (tester) async {
    // A rider whose fix never lands must never be trapped watching a ring.
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PreparingScreen(
          originName: 'Shahad',
          destinationName: 'Kalyan',
          steps: stateASteps,
          onCancel: () => cancelled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('preparing_cancel')));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });
}
