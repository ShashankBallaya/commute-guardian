import 'dart:convert';
import 'dart:io';

import 'announcement_templates.dart';
import 'ride_progress.dart';

/// Which clip kind may stand in for a spoken announcement, or null when the
/// device TTS floor keeps it.
///
/// The rule that keeps this safe (ADR 0001, owner decision 17 Jul): a clip
/// may replace an utterance ONLY when the sentence is byte-identical to the
/// template the clip was cut from. Anything dynamic misses the comparison
/// and stays on the floor: the Thane interchange script, the post-call
/// catch-ups, every sentence a template does not cover. Never splice a clip
/// name into a TTS sentence; the mid-sentence voice switch sounds worse
/// than either voice on its own.
///
/// An ordinary station's arrival announcement speaks the approach wording
/// ("Now approaching X."), so it maps to the approach clip; the destination
/// arrival has its own clip.
ClipKind? announcementClipKind({
  required Announcement announcement,
  required String stationName,
}) {
  final text = announcement.text;
  switch (announcement.kind) {
    case AnnouncementKind.approach:
    case AnnouncementKind.arrival:
      if (text == ClipKind.approach.render(stationName)) {
        return ClipKind.approach;
      }
      if (text == ClipKind.destination.render(stationName)) {
        return ClipKind.destination;
      }
      return null;
    case AnnouncementKind.passed:
      return text == ClipKind.passed.render(stationName)
          ? ClipKind.passed
          : null;
    case AnnouncementKind.overshoot:
      return text == ClipKind.overshoot.render(stationName)
          ? ClipKind.overshoot
          : null;
  }
}

/// The on-device Sarvam clip pack: `{stationId}__{kind}.wav` files plus a
/// `manifest.json` under one language directory.
///
/// Debug delivery is `adb push build/sarvam_clips/en-IN` into the app's
/// external files dir (`clips/en-IN`, the same adb-reachable spot the ride
/// logs live in), which keeps 125 MB of audio out of the APK while store
/// delivery is still an open ADR.
///
/// WHY THE MANIFEST EXISTS: matching on filename alone is not enough to
/// honour the byte-identical rule. The pack is pushed out of band and the
/// station JSON is GENERATED (tool/build_stations.py, and the 17 Jul
/// Devanagari overrides changed names in exactly this way), so a pack cut
/// before a name change would keep passing a code-string-to-code-string
/// check while playing audio that names a different station. The manifest
/// records the exact sentence every clip was cut from, and a clip is used
/// only when that recorded sentence matches what the app is about to say.
/// A pack with no manifest is treated as unusable: the device TTS floor is
/// the locked default (ADR 0001), so refusing a clip is always safe.
class ClipLibrary {
  ClipLibrary._(this.root, this._sentences);

  final Directory root;

  /// `{stationId}__{kind}` to the exact sentence that clip was cut from.
  final Map<String, String> _sentences;

  /// How many clips the manifest vouches for. Logged at startup so a stale
  /// or truncated pack is visible on the bench rather than at 6 a.m.
  int get length => _sentences.length;

  /// Opens the pack at [root], or returns null when there is no readable
  /// manifest. A malformed manifest is the same as an absent one: refusing
  /// every clip is the safe direction.
  static ClipLibrary? open(Directory root) {
    final manifest = File('${root.path}${Platform.pathSeparator}'
        'manifest.json');
    if (!manifest.existsSync()) return null;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map) return null;
      return ClipLibrary._(root, {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      });
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// The clip for a station and kind, or null when the manifest does not
  /// vouch for [expectedSentence] or the file is not on disk.
  File? clipFor(
    String stationId,
    ClipKind kind, {
    required String expectedSentence,
  }) {
    final key = '${stationId}__${kind.fileSuffix}';
    if (_sentences[key] != expectedSentence) return null;
    final file = File('${root.path}${Platform.pathSeparator}$key.wav');
    return file.existsSync() ? file : null;
  }
}
