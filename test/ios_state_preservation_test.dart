import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UIKit state preservation is OFF, and a test holds it there.
///
/// THE 16 AUG 2026 RIDE IS WHY THIS FILE EXISTS. iOS killed Travel Mode on the
/// way back from CSMT with 0x8BADF00D, a scene-update watchdog transgression,
/// for spending more than ten seconds going into the background. The crash
/// report names the work: `_saveApplicationPreservationState`, archiving UIKit
/// state through `_UIStateRestorationKeyedArchiverDelegate`. The ride stopped,
/// nothing was announced again, and no history row was ever written.
///
/// `FlutterAppDelegate` answers YES to both save questions unconditionally,
/// without asking whether the app uses restoration. This one does not: there is
/// no `restorationScopeId` and no `RestorationMixin` anywhere in lib/. So the
/// archive was pure cost.
///
/// Enforcement by test, like the isolate boundary next door, because the thing
/// being protected is a DEFAULT: delete four small methods and the behaviour
/// comes back silently, on a platform this project cannot compile or run at the
/// desk. The failure would not appear until somebody lost a ride.
void main() {
  final source = File(
    'ios/Runner/AppDelegate.swift',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  /// [code] with every comment line removed, whitespace collapsed.
  ///
  /// COMMENTS STRIPPED ON PURPOSE. Five guards in this project have passed on
  /// prose that merely mentioned the thing they were meant to find, and the
  /// block above these overrides discusses them at length.
  String bodyOf(String code) => code
      .split('\n')
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//') && !trimmed.startsWith('///');
      })
      .join('\n')
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Whether [code] really refuses [question], rather than mentioning it.
  bool refuses(String code, String question) => bodyOf(
    code,
  ).contains('$question coder: NSCoder ) -> Bool { false }');

  group('THE APP NEVER ARCHIVES UIKIT STATE', () {
    // The two iOS 13+ actually calls.
    test('it refuses to save secure application state', () {
      expect(
        refuses(source, 'shouldSaveSecureApplicationState'),
        isTrue,
        reason: 'this is the archive that cost the 16 Aug 2026 ride',
      );
    });

    test('and refuses to restore it', () {
      expect(refuses(source, 'shouldRestoreSecureApplicationState'), isTrue);
    });

    // And the legacy pair, so lowering the deployment target cannot quietly
    // switch the behaviour back on.
    test('the pre-iOS 13 pair is refused too', () {
      expect(refuses(source, 'shouldSaveApplicationState'), isTrue);
      expect(refuses(source, 'shouldRestoreApplicationState'), isTrue);
    });

    test('AND THE GUARD CAN STILL FAIL', () {
      // A guard nobody has watched fail is not a guard. Neither a comment
      // naming the method nor an override that answers TRUE may satisfy it.
      const mentionedOnly = '''
class AppDelegate {
  // shouldSaveSecureApplicationState coder: NSCoder ) -> Bool { false }
  override func application(
    _ application: UIApplication,
    shouldSaveSecureApplicationState coder: NSCoder
  ) -> Bool {
    true
  }
}
''';
      expect(
        refuses(mentionedOnly, 'shouldSaveSecureApplicationState'),
        isFalse,
      );
    });
  });

  group('AND NOTHING IN DART ASKS FOR RESTORATION', () {
    // The other half of the argument. Turning preservation off is only free
    // while the app reads none of it back, so this fails the day somebody adds
    // a restoration scope and does not read this file.
    test('no restorationScopeId, no RestorationMixin', () {
      final offenders = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final code = file.readAsStringSync();
        if (code.contains('restorationScopeId') ||
            code.contains('RestorationMixin') ||
            code.contains('restorationId:')) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'state restoration is disabled in AppDelegate.swift, so this data '
            'would be written and never read. Read that file before adding it.',
      );
    });
  });
}
