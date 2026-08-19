import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

/// Unpacks the Sarvam clip pack that ships inside the app.
///
/// WHY THIS EXISTS AT ALL, and it is the closed beta's blocker: the pack used
/// to arrive by `adb push` into the app's external files dir, and on
/// Android 11+ that directory cannot be reached without a laptop. Two phones
/// in this project have a pack; nobody else's ever could. A volunteer rode on
/// the device TTS floor and paid the 500 to 900 ms of cold start every
/// station costs an idle engine (measured 16 Aug 2026), which is not the
/// voice this product should introduce itself with.
///
/// docs/adr/0001 left delivery open because 891 WAV files are 128.7 MB. The
/// answer turned out to be a FORMAT, not a mechanism: 32 kbps mono AAC is a
/// measured 9.5x smaller, the pack is 13.5 MB, and it simply fits in the APK.
///
/// WHY UNPACK RATHER THAN PLAY THE ASSET DIRECTLY. Playback and matching read
/// `File`s from one directory (ClipLibrary, `_playClipFile`), that path has
/// been ridden, and rewriting it to take an asset key would rewrite the audio
/// code on the evening a build goes to strangers. Copying instead leaves every
/// line of the ride path untouched. It costs 13.5 MB of duplicated storage,
/// and it keeps `adb push` working as the way to try a re-cut clip without a
/// rebuild.
class BundledClips {
  const BundledClips._();

  /// Languages with a pack inside the app. Hindi has 864 clips and no
  /// manifest and its templates moved under `f0ad04a`, so it is stale rather
  /// than missing; Marathi has 9. Both are why the Settings picker offers
  /// English alone.
  static const bundled = [AppLanguage.english];

  /// A copy of the manifest the last install wrote, kept beside the language
  /// directories rather than inside one.
  ///
  /// OUTSIDE ON PURPOSE. The documented kill switch for a bad pack is to
  /// rename `clips/en-IN` out of the way; a stamp stored inside would go with
  /// it and the next launch would helpfully put the pack back.
  static const stampName = '.bundled_manifest.json';

  /// Where a pack lives, one directory per language tag.
  ///
  /// SHARED WITH THE SERVICE ISOLATE so the writer and the reader cannot
  /// drift. The two platforms differ only because they expose different
  /// reachable directories: Android keeps the external files dir it has used
  /// since 20 Jul, and iOS uses Documents, which `UIFileSharingEnabled`
  /// already shows to Finder and the Apple Devices app.
  ///
  /// The per-language directory is what makes a pack physically unable to play
  /// under the wrong voice: a Hindi ride looks in `clips/hi-IN`, finds
  /// nothing, and speaks Hindi through TTS rather than finding English audio
  /// that matches no sentence.
  static Future<Directory?> clipsRoot() async {
    final dir = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getApplicationDocumentsDirectory();
    return dir == null ? null : Directory('${dir.path}/clips');
  }

  /// Writes any bundled pack that is not already on disk. Returns a line per
  /// language for the log, and never throws: a ride with no pack speaks the
  /// identical sentences through device TTS, so every failure here is a
  /// downgrade and none is an outage.
  ///
  /// NOT ON THE RIDE PATH. This runs at launch, and a ride that starts before
  /// it finishes simply finds no pack and uses the floor.
  static Future<List<String>> install({AssetBundle? bundle, Directory? into}) async {
    final assets = bundle ?? rootBundle;
    final root = into ?? await clipsRoot();
    if (root == null) return ['CLIPS bundle: no writable directory'];

    final lines = <String>[];
    for (final language in bundled) {
      try {
        lines.add(await _installOne(language, assets, root));
      } catch (error) {
        lines.add('CLIPS bundle ${language.tag} failed: $error');
      }
    }
    return lines;
  }

  static Future<String> _installOne(
    AppLanguage language,
    AssetBundle bundle,
    Directory root,
  ) async {
    final assetDir = 'assets/clips/${language.tag}';
    final manifest = await bundle.loadString('$assetDir/manifest.json');

    // THE MANIFEST IS ITS OWN VERSION STAMP. Comparing the bytes is exact,
    // needs no hash and no version integer somebody must remember to bump,
    // and it is the file that decides which clips may play at all. A re-cut
    // pack changes a sentence or a key and this misses; an unchanged pack
    // costs one 60 KB string read per launch.
    final stamp = File('${root.path}${Platform.pathSeparator}$stampName');
    if (stamp.existsSync() && await stamp.readAsString() == manifest) {
      return 'CLIPS bundle ${language.tag}: already installed';
    }

    final keys = _keysOf(manifest);
    final target = Directory(
      '${root.path}${Platform.pathSeparator}${language.tag}',
    );
    await target.create(recursive: true);

    var written = 0;
    for (final key in keys) {
      final data = await bundle.load('$assetDir/$key.m4a');
      await File(
        '${target.path}${Platform.pathSeparator}$key.m4a',
      ).writeAsBytes(data.buffer.asUint8List(), flush: false);
      written++;
    }

    // THE MANIFEST IS WRITTEN LAST, and the stamp after it. ClipLibrary
    // refuses a pack whose manifest it cannot read, so a launch interrupted
    // halfway through leaves a directory of audio no clip can be drawn from,
    // which is the safe half of the failure. The stamp last means an
    // interrupted install is retried rather than declared done.
    await File(
      '${target.path}${Platform.pathSeparator}manifest.json',
    ).writeAsString(manifest, flush: true);
    await stamp.writeAsString(manifest, flush: true);
    return 'CLIPS bundle ${language.tag}: wrote $written clips '
        'to ${target.path}';
  }

  /// The manifest's keys, `{stationId}__{kind}` and never an extension, which
  /// is why the WAV to M4A change never had to touch the manifest.
  static List<String> _keysOf(String manifest) {
    final decoded = jsonDecode(manifest);
    if (decoded is! Map) return const [];
    return decoded.keys.whereType<String>().toList(growable: false);
  }
}
