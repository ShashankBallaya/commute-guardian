import 'dart:io';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen 6, Settings.
///
/// Most of these pin things that are ABSENT. This screen's design is mostly a
/// set of decisions about what not to put on it, and an absence is exactly the
/// kind of thing a later change reintroduces by accident.
void main() {
  Future<List<String>> pumpSettings(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    Set<AppLanguage> languages = const {AppLanguage.english},
    List<ReadinessItem>? readiness,
  }) async {
    // THE 3T'S REAL GEOMETRY, 1080x1920 at dpr 3, so 360x640 logical. The
    // default 800x600 test surface is not a phone in any orientation, and this
    // project has shipped two layouts that passed everywhere except on the
    // device. Testing at the target size is the cheap half of that lesson.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          settings: settings,
          availableLanguages: languages,
          versionLine: 'Commute Guardian 1.0.0 (1)',
          readiness:
              readiness ??
              const [
                ReadinessItem(
                  label: 'Location, always',
                  state: ReadinessState.ok,
                ),
                ReadinessItem(
                  label: 'Battery use',
                  state: ReadinessState.needsAttention,
                  detail: 'Restricted. Android may stop the app mid journey.',
                ),
              ],
          onBack: () => changes.add('back'),
          onPulseInterval: (m) => changes.add('interval:$m'),
          onCrowdMode: (v) => changes.add('crowd:$v'),
          onVibrateWithPulse: (v) => changes.add('vibrate:$v'),
          onAnnounceEveryStation: (v) => changes.add('announce:$v'),
          onShareAnonymousUsage: (v) => changes.add('usage:$v'),
          onLanguage: (l) => changes.add('language:${l.tag}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  /// The screen is about a screen and a half tall, and a ListView does not
  /// build what is below the fold, so anything past the pulse card has to be
  /// scrolled to before it exists to be found.
  ///
  /// scrollUntilVisible alone is not enough: it stops as soon as the finder
  /// matches, and a ListView builds a little beyond the fold, so the widget
  /// exists while still being off screen and untappable. ensureVisible finishes
  /// the job.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets('THE WAKE CONTROLS ARE NOT ON THIS SCREEN', (tester) async {
    // Not an oversight, a rule. Screen 4's WakeChoice toggle owns when the
    // alarm fires, and a second control here would become a second way to
    // change leadTimeS, which is locked at 90 s. Alarm volume is absent for a
    // blunter reason: its only function would be to make the alarm worse at
    // the one job this product exists to do.
    await pumpSettings(tester);

    expect(find.textContaining('stations before'), findsNothing);
    expect(find.textContaining('Wake'), findsNothing);
    expect(find.textContaining('volume', findRichText: true), findsNothing);
    expect(find.textContaining('Alarm'), findsNothing);
  });

  testWidgets('vibration is scoped to the pulse, and says so', (tester) async {
    // `vibration` is wired into the wake ladder through wake_alert_output.dart,
    // so a plain haptics toggle would let a rider quietly disable half of their
    // own alarm. The guarantee is stated rather than left to be discovered.
    await pumpSettings(tester);

    expect(find.text('Vibrate with the pulse'), findsOneWidget);
    expect(find.text('The wake alarm always vibrates.'), findsOneWidget);
  });

  testWidgets('HINDI AND MARATHI ARE SHOWN, AND CANNOT BE PICKED', (
    tester,
  ) async {
    // LOCKED 19 Aug 2026 for the closed beta, and shown on purpose. The lock
    // is about audio: only English has a clip pack bundled in the app, so a
    // Hindi rider would hear the wake ladder in the device TTS voice the
    // Sarvam work exists to replace. Hiding them would tell a Mumbai commuter
    // the app was never built for them.
    final changes = await pumpSettings(
      tester,
      languages: {AppLanguage.english, AppLanguage.hindi, AppLanguage.marathi},
    );
    await scrollTo(tester, find.text('मराठी'));

    expect(find.text('English'), findsOneWidget);
    expect(find.text('हिंदी'), findsOneWidget);
    expect(find.text('मराठी'), findsOneWidget);
    expect(find.textContaining('coming soon'), findsOneWidget);

    // THE PRESS MUST DO NOTHING. A locked control that still fires its
    // callback is worse than an absent one: the rider believes they changed
    // the voice and finds out on a train.
    await tester.tap(find.text('मराठी'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('हिंदी'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
  });

  testWidgets('the lock does not depend on which voices the device has', (
    tester,
  ) async {
    // The old rule offered whatever TtsLanguageGateway found, so a phone with
    // no Hindi voice hid Hindi for a completely different reason. Both phones
    // must now draw the same three segments, or the test above proves nothing
    // about a real rider's phone.
    await pumpSettings(tester);
    await scrollTo(tester, find.text('Voice'));

    expect(find.text('हिंदी'), findsOneWidget);
    expect(find.text('मराठी'), findsOneWidget);
    expect(find.textContaining('only speak English'), findsNothing);
  });

  testWidgets('the readiness detail appears only when it is unmet', (
    tester,
  ) async {
    // A satisfied permission needs no explanation, and explaining it anyway
    // would bury the one line that does need reading.
    await pumpSettings(tester);

    expect(find.text('Location, always'), findsOneWidget);
    expect(
      find.text('Restricted. Android may stop the app mid journey.'),
      findsOneWidget,
    );
    expect(find.text('Fix'), findsNothing); // no onFix given in this fixture
  });

  testWidgets('Fix is offered only on the row that needs fixing', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      readiness: [
        const ReadinessItem(
          label: 'Location, always',
          state: ReadinessState.ok,
        ),
        ReadinessItem(
          label: 'Battery use',
          state: ReadinessState.needsAttention,
          detail: 'Restricted.',
          onFix: () {},
        ),
      ],
    );
    expect(find.text('Fix'), findsOneWidget);
  });

  testWidgets('the interval reports the minutes, and Off is zero', (
    tester,
  ) async {
    final changes = await pumpSettings(tester);

    await tester.tap(find.text('5 min'));
    await tester.pumpAndSettle();
    expect(changes, contains('interval:5'));

    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(changes, contains('interval:0'));
  });

  testWidgets('the pulse is OFF by default', (tester) async {
    // A product decision, not an oversight. A rider installs this to be woken
    // at their stop; a chime every three minutes they never asked for is a
    // surprise in their ears.
    const settings = AppSettings();
    expect(settings.pulseIntervalMinutes, 0);
    expect(settings.pulseIntervalSeconds, isNull);

    await pumpSettings(tester);
    // "Off" is the selected segment, so it is the bold green one.
    await scrollTo(tester, find.text('Off'));
    final off = tester.widget<Text>(find.text('Off'));
    expect(off.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('crowd mode overrides the interval', (tester) async {
    const settings = AppSettings(pulseIntervalMinutes: 10, crowdMode: true);
    expect(settings.pulseIntervalSeconds, 45);
  });

  testWidgets('the version line is on the screen', (tester) async {
    // Small, and it is the line every support conversation starts with. This
    // app already gets false-positive antivirus flags on its debug builds.
    await pumpSettings(tester);
    await scrollTo(tester, find.text('Commute Guardian 1.0.0 (1)'));
    expect(find.text('Commute Guardian 1.0.0 (1)'), findsOneWidget);
  });

  testWidgets('NOTHING ON THIS SCREEN IS CRIMSON', (tester) async {
    // Crimson starts or ends a JOURNEY. No control here does either, so the
    // app's one accent simply must not appear.
    await pumpSettings(
      tester,
      readiness: [
        ReadinessItem(
          label: 'Battery use',
          state: ReadinessState.needsAttention,
          detail: 'Restricted.',
          onFix: () {},
        ),
      ],
    );

    final crimsonBoxes = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) {
          final decoration = c.decoration;
          return decoration is BoxDecoration &&
              decoration.color == const Color(0xFF55131D);
        });
    expect(crimsonBoxes, isEmpty);
  });
  test('THE VIBRATION SWITCH IS OFFERED ON BOTH PLATFORMS', () {
    // REVERSED 12 Aug 2026 by `docs/adr/0003`, and the earlier version of this
    // test was right for as long as its premise held. It asserted the row was
    // HIDDEN on iOS, because iOS was believed to forbid background haptics and
    // a control that cannot act invites a rider to solve a problem with a
    // switch that will not solve it.
    //
    // An iPhone then buzzed 7 times out of 7 from a locked pocket. Hiding the
    // row now produces the mirror-image fault: an iPhone buzzing every 45
    // seconds with nothing in the app that can stop it. Last time the switch
    // could not act; this time the rider could not.
    //
    // Read from the source, because a platform branch cannot be overridden in
    // a widget test: whichever branch the host takes is the only one that
    // renders, so a rendering test can never see the platform it is not.
    final source = File('lib/screens/settings_screen.dart').readAsStringSync();
    expect(
      source.contains("switchKey: const Key('settings_vibrate')"),
      isTrue,
      reason: 'the row must exist',
    );

    // No platform branch anywhere in this screen. Blunt on purpose: a guard
    // that named only the old `!Platform.isIOS` spelling would pass against a
    // reintroduced `Platform.isAndroid`, which is the same trap five earlier
    // source-reading guards in this project fell into.
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(
      code.contains('Platform.'),
      isFalse,
      reason: 'the settings screen must render the same on both platforms',
    );
  });
}
