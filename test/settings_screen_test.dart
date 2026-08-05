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

  testWidgets('A LANGUAGE WITH NO VOICE IS NEVER OFFERED', (tester) async {
    // The failure mode is not a cosmetic fallback. A rider who selects a
    // language the device cannot speak gets SILENCE from the wake alarm.
    await pumpSettings(tester);
    await scrollTo(tester, find.text('Voice'));

    expect(find.text('हिंदी'), findsNothing);
    expect(find.text('मराठी'), findsNothing);
    // And it explains itself rather than showing a picker with one option.
    expect(find.textContaining('only speak English'), findsOneWidget);
  });

  testWidgets('a device with the voices offers them in native script', (
    tester,
  ) async {
    final changes = await pumpSettings(
      tester,
      languages: {AppLanguage.english, AppLanguage.hindi, AppLanguage.marathi},
    );

    await scrollTo(tester, find.text('मराठी'));

    expect(find.text('English'), findsOneWidget);
    expect(find.text('हिंदी'), findsOneWidget);
    expect(find.text('मराठी'), findsOneWidget);

    await tester.tap(find.text('मराठी'));
    await tester.pumpAndSettle();
    expect(changes, contains('language:mr-IN'));
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
}
