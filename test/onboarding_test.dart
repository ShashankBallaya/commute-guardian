import 'package:commute_guardian/screens/onboarding_screen.dart';
import 'package:commute_guardian/services/permissions_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Onboarding, six screens.
///
/// The rules under test are the ones that decide whether a stranger can use
/// this app at all: the disclosure comes BEFORE the system prompt (a Play
/// requirement, not a preference), refusing never traps anyone, and the
/// background-location screen exists because Android will not grant it from a
/// dialog.
class _FakePermissions implements PermissionsGateway {
  _FakePermissions({this.android = true});

  final bool android;
  final List<String> asked = [];
  bool whileInUseGranted = true;

  @override
  bool get isAndroid => android;

  @override
  Future<bool> requestWhileInUse() async {
    asked.add('whileInUse');
    return whileInUseGranted;
  }

  @override
  Future<bool> requestAlways() async {
    asked.add('always');
    return false;
  }

  @override
  Future<bool> requestNotifications() async {
    asked.add('notifications');
    return true;
  }

  @override
  Future<bool> openSettings() async {
    asked.add('openSettings');
    return true;
  }

  @override
  Future<bool> hasWhileInUse() async => whileInUseGranted;
  @override
  Future<bool> hasAlways() async => false;
  @override
  Future<bool> hasNotifications() async => true;
}

void main() {
  Future<(_FakePermissions, List<String>)> pump(
    WidgetTester tester, {
    bool android = true,
  }) async {
    final permissions = _FakePermissions(android: android);
    final done = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          permissionsGatewayProvider.overrideWithValue(permissions),
        ],
        child: MaterialApp(
          home: OnboardingScreen(onDone: () => done.add('done')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (permissions, done);
  }

  Future<void> act(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('onboarding_action')));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the promise, not on a permission request', (
    tester,
  ) async {
    final (permissions, _) = await pump(tester);

    expect(find.byKey(const Key('onboarding_welcome')), findsOneWidget);
    expect(find.text('Never miss your station'), findsOneWidget);
    // Nothing has been asked for yet. Asking on screen one is how apps get
    // refused, and on Play it is how they get rejected.
    expect(permissions.asked, isEmpty);
  });

  testWidgets('the disclosure comes BEFORE the system prompt', (tester) async {
    final (permissions, _) = await pump(tester);
    await act(tester); // leave welcome

    expect(find.byKey(const Key('onboarding_disclosure')), findsOneWidget);
    // Play requires all four: what, why, that it is background, and an
    // affirmative action.
    expect(find.textContaining('in the background'), findsOneWidget);
    expect(find.textContaining('announce each station'), findsOneWidget);
    expect(find.textContaining('never leaves your phone'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    // Still nothing asked: the disclosure is shown FIRST, then the prompt.
    expect(permissions.asked, isEmpty);

    await act(tester);
    expect(permissions.asked, ['whileInUse']);
  });

  testWidgets('background location gets its own screen, because Android '
      'will not grant it from a dialog', (tester) async {
    final (permissions, _) = await pump(tester);
    await act(tester); // welcome
    await act(tester); // disclosure, asks whileInUse

    expect(find.byKey(const Key('onboarding_background')), findsOneWidget);
    // The label the rider must hunt for is Android's wording, not ours.
    expect(find.text('Choose "Allow all the time"'), findsOneWidget);

    await act(tester);
    expect(permissions.asked, ['whileInUse', 'openSettings']);
  });

  testWidgets('refusing every step still reaches the end', (tester) async {
    final (permissions, done) = await pump(tester);
    await act(tester); // welcome has no skip

    // Refusing is a legitimate answer: the app degrades, it does not trap.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('onboarding_skip')));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);
    expect(permissions.asked, isEmpty);

    await act(tester);
    expect(done, ['done']);
  });

  testWidgets('every step advances, and the last one finishes', (tester) async {
    final (permissions, done) = await pump(tester);
    for (var i = 0; i < 6; i++) {
      await act(tester);
    }

    expect(done, ['done']);
    expect(permissions.asked, ['whileInUse', 'openSettings', 'notifications']);
  });

  testWidgets('iOS skips the battery screen rather than promising nothing', (
    tester,
  ) async {
    final (_, done) = await pump(tester, android: false);
    await act(tester); // welcome
    await act(tester); // disclosure
    await act(tester); // background
    await act(tester); // notifications

    // Step 4 is Android-only, so iOS lands straight on the last screen.
    expect(find.byKey(const Key('onboarding_battery')), findsNothing);
    expect(find.byKey(const Key('onboarding_ready')), findsOneWidget);

    await act(tester);
    expect(done, ['done']);
  });
}
