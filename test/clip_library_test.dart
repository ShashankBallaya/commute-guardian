import 'dart:convert';
import 'dart:io';

import 'package:commute_guardian/services/announcement_templates.dart';
import 'package:commute_guardian/services/clip_library.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:flutter_test/flutter_test.dart';

Announcement _a(AnnouncementKind kind, String stationId, String text) =>
    Announcement(stationId: stationId, kind: kind, text: text);

/// A pack on disk: the named clips plus a manifest vouching for each one.
/// [manifest] defaults to the true sentences, so a test only spells it out
/// when it wants a stale or missing one.
Directory _pack(
  Map<String, String> clips, {
  Map<String, String>? manifest,
  bool withManifest = true,
}) {
  final dir = Directory.systemTemp.createTempSync('clip_pack');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final key in clips.keys) {
    File(
      '${dir.path}${Platform.pathSeparator}$key.wav',
    ).writeAsBytesSync(const [0]);
  }
  if (withManifest) {
    File(
      '${dir.path}${Platform.pathSeparator}manifest.json',
    ).writeAsStringSync(jsonEncode(manifest ?? clips));
  }
  return dir;
}

void main() {
  test('template-matching sentences map to their clip kinds', () {
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.approach,
          'thane',
          'Now approaching Thane.',
        ),
        stationName: 'Thane',
      ),
      ClipKind.approach,
    );
    // An ordinary station's arrival speaks the approach wording, so it uses
    // the approach clip.
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.arrival,
          'kalwa',
          'Now approaching Kalwa.',
        ),
        stationName: 'Kalwa',
      ),
      ClipKind.approach,
    );
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.arrival,
          'nerul',
          'You have arrived at your destination, Nerul.',
        ),
        stationName: 'Nerul',
      ),
      ClipKind.destination,
    );
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.passed,
          'rabale',
          'You have passed Rabale.',
        ),
        stationName: 'Rabale',
      ),
      ClipKind.passed,
    );
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.overshoot,
          'shahad',
          'You have passed your stop. It is alright. Please alight here, '
              'at Shahad.',
        ),
        stationName: 'Shahad',
      ),
      ClipKind.overshoot,
    );
  });

  test('dynamic sentences never map to a clip (the ADR device-TTS floor)', () {
    // The Thane interchange script is composed at plan time; no closed-set
    // clip covers it, and splicing voices mid-ride is worse than TTS.
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.arrival,
          'thane',
          'You have reached Thane. Change here to the Trans Harbour line. '
              'Get off the train, go to platform number 9, 10, or 10 A, then '
              'board the Trans Harbour train to continue to your destination.',
        ),
        stationName: 'Thane',
      ),
      isNull,
    );
    // A sentence that names a DIFFERENT station than the announcement's own
    // must not match either: the byte-identical rule is per station.
    expect(
      announcementClipKind(
        announcement: _a(
          AnnouncementKind.approach,
          'thane',
          'Now approaching Kalwa.',
        ),
        stationName: 'Thane',
      ),
      isNull,
    );
  });

  test('a manifest-vouched clip that exists on disk is played', () {
    final library = ClipLibrary.open(
      _pack({'thane__approach': 'Now approaching Thane.'}),
    );
    expect(
      library!.clipFor(
        'thane',
        ClipKind.approach,
        expectedSentence: 'Now approaching Thane.',
      ),
      isNotNull,
    );
    expect(library.length, 1);
  });

  test('a pack with no manifest is refused entirely', () {
    // The device TTS floor is the locked default, so an unverifiable pack
    // must yield nothing rather than trust its filenames.
    expect(
      ClipLibrary.open(
        _pack({
          'thane__approach': 'Now approaching Thane.',
        }, withManifest: false),
      ),
      isNull,
    );
  });

  test('a malformed manifest is refused like an absent one', () {
    final dir = Directory.systemTemp.createTempSync('clip_pack_bad');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(
      '${dir.path}${Platform.pathSeparator}manifest.json',
    ).writeAsStringSync('{not json');
    expect(ClipLibrary.open(dir), isNull);
  });

  test('a STALE clip is refused: the manifest sentence must match', () {
    // The 17 Jul Devanagari overrides renamed stations in exactly this way.
    // The clip file is present and correctly named, but it was cut from the
    // old sentence, so playing it would announce the wrong words.
    final library = ClipLibrary.open(
      _pack(
        {'shahad__approach': 'Now approaching Shahad.'},
        manifest: {'shahad__approach': 'Now approaching Shahad Junction.'},
      ),
    );
    expect(
      library!.clipFor(
        'shahad',
        ClipKind.approach,
        expectedSentence: 'Now approaching Shahad.',
      ),
      isNull,
    );
  });

  test('a manifest entry with no audio file on disk is refused', () {
    final library = ClipLibrary.open(
      _pack(const {}, manifest: {'thane__approach': 'Now approaching Thane.'}),
    );
    expect(
      library!.clipFor(
        'thane',
        ClipKind.approach,
        expectedSentence: 'Now approaching Thane.',
      ),
      isNull,
    );
  });

  group('the clip path is not an Android feature', () {
    // The owner asked for clips on iOS on 13 Aug 2026, because the device TTS
    // voice is not good enough to be the product's voice. The pack was never
    // iOS-hostile: ClipLibrary is pure dart:io, and playback is audioplayers
    // with a DeviceFileSource, which iOS has always supported. What made it
    // Android-only was ONE call, getExternalStorageDirectory(), which does not
    // exist on iOS, and the `&& Platform.isAndroid` written to guard it.
    //
    // The service cannot be constructed under the test binding, so this is a
    // source guard rather than a behavioural one. It is written the way
    // pressable_test.dart's guard had to be rewritten five times: comments
    // stripped first, and a test below that proves it can still fail.
    // \r stripped as well as comments: the working tree is CRLF on Windows,
    // and a multi-line expectation written with \n silently never matches.
    String serviceCode() => File('lib/services/geofence_chain_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    /// The condition of the `if (sarvamClips ...)` that opens the pack.
    String clipGateCondition(String code) {
      final match = RegExp(r'if \(sarvamClips([^)]*)\)').firstMatch(code);
      expect(
        match,
        isNotNull,
        reason: 'the clip gate itself has moved or been renamed',
      );
      return match!.group(1)!;
    }

    test('NO PLATFORM CHECK GATES THE CLIP PACK. iOS reaching this code is '
        'the whole point of the change', () {
      expect(clipGateCondition(serviceCode()), isNot(contains('Platform')));
    });

    test('and the guard can still fail, on the exact line it used to read', () {
      const old = 'if (sarvamClips && Platform.isAndroid) {';
      expect(clipGateCondition(old), contains('Platform'));
    });

    test('ANDROID STILL READS ITS OWN DIRECTORY, so no pack already pushed to '
        'a device moves', () {
      final code = serviceCode();
      expect(code, contains('getExternalStorageDirectory()'));
      expect(code, contains('getApplicationDocumentsDirectory()'));
      // The Android arm of the ternary, so the two cannot be swapped silently
      // and iOS given the directory that only exists on Android.
      expect(
        RegExp(
          r'Platform\.isAndroid\s*\?\s*await getExternalStorageDirectory\(\)',
        ).hasMatch(code),
        isTrue,
        reason: 'Android must keep the external files dir it already uses',
      );
    });

    test('CLIPS AND SPEECH SHARE ONE QUEUE, so a clip cannot start on top of '
        'a half-spoken line', () {
      // The 13 Aug 2026 ride opened with the welcome at 17:14:04.023 and the
      // origin's clip at 17:14:04.033, two voices at once. They were two
      // separate chains, and the comment on the clip chain accepted that race
      // because "Android TTS gives no completion to await mid-ride". That
      // premise died on 30 Jul when _utteranceDone was added.
      final code = serviceCode();
      expect(
        code,
        contains('_audioChain = _audioChain'),
        reason: 'the clip queue and the speech queue must be the same future',
      );
      expect(
        code,
        isNot(contains('_clipChain')),
        reason: 'a second queue is the bug coming back',
      );
    });

    test('AND THE CLIP FALLBACK MUST NOT RE-ENTER THAT QUEUE, or the ride '
        'deadlocks on its first failed clip', () {
      // _enqueueClip's catch runs INSIDE _audioChain. Calling _speak there
      // appends to the same chain and awaits it, which cannot complete until
      // the code doing the awaiting returns. Two separate queues hid this;
      // one queue makes it fatal, and a failed clip is not rare (4 of 14 on
      // the 13 Aug ride).
      final code = serviceCode();
      final start = code.indexOf('void _enqueueClip(');
      expect(start, greaterThan(-1), reason: '_enqueueClip has been renamed');
      final body = code.substring(start, code.indexOf('\n  }', start));

      expect(body, contains('_speakNow('));
      expect(
        RegExp(r'await _speak\(').hasMatch(body),
        isFalse,
        reason: 'the fallback must call _speakNow, never the queueing _speak',
      );
    });

    test('iOS EXPOSES ITS DOCUMENTS FOLDER, or the pack cannot be delivered '
        'to the phone at all', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      // Both keys, each immediately followed by <true/>. Checking the key
      // alone would pass on a plist that sets it false.
      for (final key in const [
        'UIFileSharingEnabled',
        'LSSupportsOpeningDocumentsInPlace',
      ]) {
        expect(
          RegExp('<key>$key</key>\\s*<true/>').hasMatch(plist),
          isTrue,
          reason: '$key must be present AND true',
        );
      }
    });
  });
}
