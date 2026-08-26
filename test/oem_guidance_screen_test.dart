import 'package:commute_guardian/screens/oem_guidance_screen.dart';
import 'package:commute_guardian/services/oem_guidance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen that tells a rider what their own phone brand does to this app.
///
/// WHAT IS BEING PROTECTED HERE IS AN HONESTY RULE, not a layout. Nothing on
/// this screen can be read back from the platform, so the screen must never
/// claim the setting is done, and it must never offer a button that does
/// nothing. Both of those are one careless edit away and neither would fail a
/// build.
void main() {
  final guidance = oemGuidanceFor(
    const OemDevice(manufacturer: 'Xiaomi', brand: 'Redmi'),
  );

  Future<List<String>> pumpGuidance(
    WidgetTester tester, {
    String? opens = 'com.miui.securitycenter/x',
    bool acknowledged = false,
  }) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: OemGuidanceScreen(
          guidance: guidance,
          acknowledged: acknowledged,
          onBack: () => events.add('back'),
          onOpenSetting: () async {
            events.add('open');
            return opens;
          },
          onAcknowledge: () => events.add('acknowledged'),
        ),
      ),
    );
    // The steps stagger in over 40 ms each. Settle past the whole cascade.
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return events;
  }



  /// Scrolls the document to the deep link, which lives WITH the steps.
  ///
  /// Deliberate: the button opens the screen those steps are performed on, so
  /// it belongs to them and scrolls with them. Only the confirmation is
  /// pinned, and the tests below prove that separately.
  Future<void> scrollToDeepLink(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
  }

  testWidgets('IT NAMES THE PHONE THE RIDER OWNS', (tester) async {
    await pumpGuidance(tester);

    // Redmi, not Xiaomi. A rider matching this against the back of their phone
    // is the whole reason the brand is carried separately.
    expect(find.textContaining('Redmi'), findsWidgets);
  });

  testWidgets('every step is drawn, in order, and numbered', (tester) async {
    await pumpGuidance(tester);

    for (final step in guidance.steps) {
      expect(find.text(step), findsOneWidget);
    }
    for (var i = 1; i <= guidance.steps.length; i++) {
      expect(find.text('$i'), findsOneWidget);
    }
  });

  testWidgets('the rider can say they have done it', (tester) async {
    final events = await pumpGuidance(tester);

    await tester.tap(find.byKey(const Key('oem_acknowledge')));
    await tester.pump();

    expect(events, contains('acknowledged'));
  });

  testWidgets('AN ACKNOWLEDGED SCREEN CANNOT BE ACKNOWLEDGED AGAIN', (
    tester,
  ) async {
    final events = await pumpGuidance(tester, acknowledged: true);

    await tester.tap(find.byKey(const Key('oem_acknowledge')));
    await tester.pump();

    expect(events, isNot(contains('acknowledged')));
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets(
    'A DEEP LINK THAT OPENS NOTHING IS REPLACED BY THE TRUTH',
    (tester) async {
      // The OEM components differ by skin version and several are no longer
      // exported. A button that silently does nothing is the worst thing this
      // particular screen could ship, because the rider has no other way to
      // tell whether they are looking at a broken app or a phone that just
      // works differently.
      final events = await pumpGuidance(tester, opens: null);
      await scrollToDeepLink(tester);

      expect(find.byKey(const Key('oem_open_setting')), findsOneWidget);

      await tester.tap(find.byKey(const Key('oem_open_setting')));
      await tester.pumpAndSettle();

      expect(events, contains('open'));
      expect(find.byKey(const Key('oem_open_setting')), findsNothing);
      expect(
        find.textContaining('will not open that screen directly'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a deep link that works leaves the button alone', (tester) async {
    await pumpGuidance(tester);
    await scrollToDeepLink(tester);

    await tester.tap(find.byKey(const Key('oem_open_setting')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('oem_open_setting')), findsOneWidget);
    expect(
      find.textContaining('will not open that screen directly'),
      findsNothing,
    );
  });

  testWidgets('IT NEVER CLAIMS TO HAVE CHECKED THE SETTING', (tester) async {
    await pumpGuidance(tester, acknowledged: true);

    // The rider's word is recorded as the rider's word. "Verified" or "we
    // checked" would be the one lie this screen is in a position to tell.
    expect(find.textContaining('cannot check this setting'), findsOneWidget);
  });

  testWidgets('the steps are there under reduced motion too', (tester) async {
    // The stagger is decorative and goes away, and everything it carries has
    // to still be on the screen. An animation that hides content when it is
    // switched off is a bug that only shows up for the riders least able to
    // work around it.
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: OemGuidanceScreen(
            guidance: guidance,
            onBack: () {},
            onOpenSetting: () async => null,
            onAcknowledge: () {},
          ),
        ),
      ),
    );
    // No settle: with motion off there is nothing to wait for, which is the
    // claim being tested.
    await tester.pump();

    for (final step in guidance.steps) {
      expect(find.text(step), findsOneWidget);
    }
  });

  /// THE BUG THE FIRST DRAFT SHIPPED, measured rather than argued.
  ///
  /// Everything used to live in one ListView. At 360x640, which is the 3T and
  /// the device every bench in this project runs on, "I have done this" was
  /// not merely below the fold: it was never built, so a rider met a screen
  /// whose primary action did not exist until they scrolled past five steps.
  /// Most of this market is on a phone this size or smaller.
  testWidgets(
    'THE CONFIRMATION IS REACHABLE WITHOUT SCROLLING, on the smallest phone',
    (tester) async {
      // The floor overflow_test.dart measures against: a 320x568 phone, which
      // is narrower and shorter than the 3T.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpGuidance(tester);

      final ack = find.byKey(const Key('oem_acknowledge'));
      expect(ack, findsOneWidget, reason: 'it must exist without scrolling');

      final box = tester.getRect(ack);
      expect(
        box.bottom,
        lessThanOrEqualTo(568.0),
        reason: 'the primary action must be on screen, not under the fold',
      );
    },
  );

  testWidgets('and the steps still scroll under it', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpGuidance(tester);

    // The document scrolls; the control does not move with it. That is the
    // whole split, and a layout change that quietly puts the button back in
    // the list would pass every other test in this file.
    final before = tester.getRect(find.byKey(const Key('oem_acknowledge')));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byKey(const Key('oem_acknowledge')));

    expect(after, before);
  });
}
