import 'dart:io';

import 'package:commute_guardian/services/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// THE VERSION LINE MUST NAME THE BUILD IT IS PRINTED IN.
///
/// On 21 Aug 2026 the Settings screen said `Commute Guardian 1.0.0 (1)` on a
/// phone running versionCode 2002, because the line was a literal at its call
/// site. A tester reading that line back to us named a build that did not
/// exist. These tests hold the two halves of the fix: the defaults track
/// `pubspec.yaml`, and no source file goes back to hardcoding the line.
void main() {
  group('BuildInfo defaults', () {
    // Tests run with no --dart-define, so this file measures exactly what a
    // developer's own `flutter run` shows.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)\+(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    test('pubspec declares a version and a build number', () {
      expect(version, isNotNull, reason: 'pubspec.yaml needs `version: x.y.z+n`');
    });

    test('the defaults track pubspec, so an un-defined build still tells truth', () {
      expect(BuildInfo.version, version!.group(1));
      expect(BuildInfo.buildNumber, version.group(2));
    });

    test('a build with no sha says so instead of naming a commit', () {
      expect(BuildInfo.isNamedBuild, isFalse);
      expect(BuildInfo.versionLine, endsWith(' local'));
      expect(
        BuildInfo.versionLine,
        'Commute Guardian ${version!.group(1)} (${version.group(2)}) local',
      );
    });
  });

  test('no screen hardcodes a version line any more', () {
    // The literal that lied. Word-anchored on the product name plus a version
    // number, so this cannot be defeated by a rename and cannot be tripped by
    // prose that merely says "Commute Guardian".
    final hardcoded = RegExp(r"'Commute Guardian \d+\.\d+\.\d+ \(\d+\)");
    final offenders = <String>[];

    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final body = file
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      if (hardcoded.hasMatch(body)) offenders.add(file.path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Use BuildInfo.versionLine. A literal cannot name its own build.',
    );
  });
}
