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
    File('${dir.path}${Platform.pathSeparator}$key.wav')
        .writeAsBytesSync(const [0]);
  }
  if (withManifest) {
    File('${dir.path}${Platform.pathSeparator}manifest.json')
        .writeAsStringSync(jsonEncode(manifest ?? clips));
  }
  return dir;
}

void main() {
  test('template-matching sentences map to their clip kinds', () {
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.approach, 'thane', 'Now approaching Thane.'),
        stationName: 'Thane',
      ),
      ClipKind.approach,
    );
    // An ordinary station's arrival speaks the approach wording, so it uses
    // the approach clip.
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.arrival, 'kalwa', 'Now approaching Kalwa.'),
        stationName: 'Kalwa',
      ),
      ClipKind.approach,
    );
    expect(
      announcementClipKind(
        announcement: _a(AnnouncementKind.arrival, 'nerul',
            'You have arrived at your destination, Nerul.'),
        stationName: 'Nerul',
      ),
      ClipKind.destination,
    );
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.passed, 'rabale', 'You have passed Rabale.'),
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
            'at Shahad.'),
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
            'board the Trans Harbour train to continue to your destination.'),
        stationName: 'Thane',
      ),
      isNull,
    );
    // A sentence that names a DIFFERENT station than the announcement's own
    // must not match either: the byte-identical rule is per station.
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.approach, 'thane', 'Now approaching Kalwa.'),
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
      library!.clipFor('thane', ClipKind.approach,
          expectedSentence: 'Now approaching Thane.'),
      isNotNull,
    );
    expect(library.length, 1);
  });

  test('a pack with no manifest is refused entirely', () {
    // The device TTS floor is the locked default, so an unverifiable pack
    // must yield nothing rather than trust its filenames.
    expect(
      ClipLibrary.open(
        _pack({'thane__approach': 'Now approaching Thane.'},
            withManifest: false),
      ),
      isNull,
    );
  });

  test('a malformed manifest is refused like an absent one', () {
    final dir = Directory.systemTemp.createTempSync('clip_pack_bad');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}${Platform.pathSeparator}manifest.json')
        .writeAsStringSync('{not json');
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
      library!.clipFor('shahad', ClipKind.approach,
          expectedSentence: 'Now approaching Shahad.'),
      isNull,
    );
  });

  test('a manifest entry with no audio file on disk is refused', () {
    final library = ClipLibrary.open(
      _pack(const {}, manifest: {'thane__approach': 'Now approaching Thane.'}),
    );
    expect(
      library!.clipFor('thane', ClipKind.approach,
          expectedSentence: 'Now approaching Thane.'),
      isNull,
    );
  });
}
