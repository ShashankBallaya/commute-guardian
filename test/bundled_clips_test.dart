import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/services/bundled_clips.dart';
import 'package:commute_guardian/services/clip_library.dart';
import 'package:commute_guardian/services/announcement_templates.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An asset bundle holding one language pack, so a test never touches the
/// real 13.5 MB one.
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.files);

  final Map<String, List<int>> files;

  /// Every key the installer asked for, in order. The point of the fake: the
  /// installer must ask for exactly the manifest's keys and nothing else.
  final asked = <String>[];

  @override
  Future<ByteData> load(String key) async {
    asked.add(key);
    final bytes = files[key];
    if (bytes == null) throw FlutterError('no asset $key');
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }
}

_FakeBundle _bundle(Map<String, String> manifest) => _FakeBundle({
  'assets/clips/en-IN/manifest.json': utf8.encode(jsonEncode(manifest)),
  for (final key in manifest.keys)
    'assets/clips/en-IN/$key.m4a': utf8.encode('audio for $key'),
});

Directory _tempRoot() {
  final dir = Directory.systemTemp.createTempSync('clips_root');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  const manifest = {
    'airoli__approach': 'Now approaching Airoli.',
    'airoli__destination': 'You have arrived at your destination, Airoli.',
  };

  test('THE PACK LANDS WHERE THE SERVICE LOOKS FOR IT', () async {
    // The whole point of the exercise. Before this, a pack arrived by
    // `adb push` into the app's external files dir, and on Android 11+ that
    // directory cannot be reached without a laptop, so a beta tester could
    // never be given one and rode on the device TTS floor.
    final root = _tempRoot();
    await BundledClips.install(bundle: _bundle(manifest), into: root);

    final pack = Directory('${root.path}${Platform.pathSeparator}en-IN');
    final clips = ClipLibrary.open(pack);
    expect(clips, isNotNull, reason: 'the written pack must open');
    expect(clips!.length, 2);
    expect(
      clips
          .clipFor(
            'airoli',
            ClipKind.approach,
            expectedSentence: 'Now approaching Airoli.',
          )
          ?.readAsStringSync(),
      'audio for airoli__approach',
    );
  });

  test('a second launch does not rewrite 13.5 MB', () async {
    final root = _tempRoot();
    await BundledClips.install(bundle: _bundle(manifest), into: root);

    // A FRESH BUNDLE, because a relaunch is a fresh process. Reusing the
    // first one would prove nothing: CachingAssetBundle caches loadString, so
    // even a re-reading installer would look free.
    final relaunch = _bundle(manifest);
    final lines = await BundledClips.install(bundle: relaunch, into: root);

    expect(lines.single, contains('already installed'));
    expect(
      relaunch.asked,
      ['assets/clips/en-IN/manifest.json'],
      reason: 'the manifest is the version stamp, and no audio follows it',
    );
  });

  test('A RE-CUT PACK REPLACES THE OLD ONE', () async {
    // The manifest is the stamp because it is the file that decides which
    // clips may play at all: change a sentence and the old audio must go.
    final root = _tempRoot();
    await BundledClips.install(bundle: _bundle(manifest), into: root);
    await BundledClips.install(
      bundle: _bundle({...manifest, 'airoli__approach': 'Airoli is next.'}),
      into: root,
    );

    final clips = ClipLibrary.open(
      Directory('${root.path}${Platform.pathSeparator}en-IN'),
    );
    expect(
      clips!.clipFor(
        'airoli',
        ClipKind.approach,
        expectedSentence: 'Airoli is next.',
      ),
      isNotNull,
    );
    expect(
      clips.clipFor(
        'airoli',
        ClipKind.approach,
        expectedSentence: 'Now approaching Airoli.',
      ),
      isNull,
    );
  });

  test('THE KILL SWITCH SURVIVES A RELAUNCH', () async {
    // The documented way to take a bad pack out of a ride, on a phone, with
    // no rebuild, is to rename clips/en-IN out of the way. If the version
    // stamp lived inside that directory it would be renamed with it and the
    // next launch would helpfully put the pack back, which is why the stamp
    // is a sibling of the language directories rather than a child.
    final root = _tempRoot();
    await BundledClips.install(bundle: _bundle(manifest), into: root);

    final pack = Directory('${root.path}${Platform.pathSeparator}en-IN');
    pack.renameSync('${root.path}${Platform.pathSeparator}en-IN.off');
    await BundledClips.install(bundle: _bundle(manifest), into: root);

    expect(pack.existsSync(), isFalse);
  });

  test('an interrupted install is retried, not declared done', () async {
    // The manifest is written after the audio and the stamp after the
    // manifest, so a launch that dies partway leaves a pack ClipLibrary
    // refuses (the safe half of the failure) and a stamp that still misses.
    final root = _tempRoot();
    final bundle = _bundle(manifest);
    final broken = _FakeBundle({
      ...bundle.files,
    }..remove('assets/clips/en-IN/airoli__destination.m4a'));

    final lines = await BundledClips.install(bundle: broken, into: root);
    expect(lines.single, contains('failed'));

    final pack = Directory('${root.path}${Platform.pathSeparator}en-IN');
    expect(ClipLibrary.open(pack), isNull, reason: 'no manifest was written');

    await BundledClips.install(bundle: bundle, into: root);
    expect(ClipLibrary.open(pack)?.length, 2);
  });

  test('NO PACK IS NEVER AN OUTAGE', () async {
    // Every failure here is a downgrade to device TTS speaking the identical
    // sentences. Nothing about a nicer voice may throw into launch.
    final lines = await BundledClips.install(
      bundle: _FakeBundle(const {}),
      into: _tempRoot(),
    );
    expect(lines.single, contains('failed'));
  });
}
