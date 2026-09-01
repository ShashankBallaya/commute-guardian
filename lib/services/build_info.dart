/// WHICH BINARY IS THIS.
///
/// Until 22 Aug 2026 the version line on the Settings screen was the literal
/// `'Commute Guardian 1.0.0 (1)'`, hardcoded at its call site. Every build ever
/// handed to anybody said the same eight characters, and on 21 Aug a bench
/// caught it lying outright: the line read `(1)` on a phone whose installed
/// package was versionCode 2002.
///
/// That is the one surface a tester can read back to us, and it could not name
/// the thing it was running. The same trap cost a whole day on 13 Aug, when an
/// IPA built from the PREVIOUS commit shipped under the new commit's name.
///
/// So the line is built from the environment now, and the build script that
/// passes [sha] also names the output file from it. A build with no [sha] is a
/// developer's own `flutter run`, and it says so.
class BuildInfo {
  const BuildInfo._();

  /// The short commit the binary was compiled from, passed by
  /// `tool/build_apk.ps1` or by the iOS workflow. Empty in a plain
  /// `flutter run`, which is a valid state, not a failure.
  ///
  /// A local build from a dirty tree carries a `-dirty` suffix, because a sha
  /// that names a commit the tree does not match is worse than no sha: it
  /// invites us to read a diff that was never in the build.
  static const sha = String.fromEnvironment('BUILD_SHA');

  /// Defaults track `pubspec.yaml`. `build_info_test.dart` fails if they drift,
  /// because a stale default here would put the project back where it started:
  /// a version line that reports a number that is not the build.
  static const version = String.fromEnvironment(
    'BUILD_VERSION',
    defaultValue: '1.0.0',
  );

  static const buildNumber = String.fromEnvironment(
    'BUILD_NUMBER',
    defaultValue: '4005',
  );

  static bool get isNamedBuild => sha.isNotEmpty;

  /// `Commute Guardian 1.0.0 (2002) 5b3d5dd`, or `... (1) local` when nothing
  /// passed a sha. Read out loud in a support conversation, so it stays one
  /// short line and puts the sha last, where it is easy to read back.
  static String get versionLine {
    final tail = isNamedBuild ? sha : 'local';
    return 'Commute Guardian $version ($buildNumber) $tail';
  }
}
