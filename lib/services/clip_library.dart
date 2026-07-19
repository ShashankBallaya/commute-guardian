import 'dart:io';

import 'ride_progress.dart';

/// Which Sarvam clip can replace a spoken announcement, or null for device
/// TTS.
///
/// The rule that keeps this safe (ADR 0001, owner decision 17 Jul): a clip
/// may replace an utterance ONLY when the code's sentence is byte-identical
/// to the template the clip was cut from (tool/build_clip_pack.py renders
/// the en-IN templates from the same station JSON, so the texts match by
/// construction). Anything dynamic misses the comparison and stays device
/// TTS: the Thane interchange script, the post-call catch-ups, every
/// sentence a template does not cover. Never splice a clip name into a TTS
/// sentence; the mid-sentence voice switch sounds worse than either voice.
///
/// An ordinary station's arrival announcement speaks the approach wording
/// ("Now approaching X."), so it maps to the approach clip; the destination
/// arrival has its own clip.
String? announcementClipKind({
  required Announcement announcement,
  required String stationName,
}) {
  final n = stationName;
  final text = announcement.text;
  switch (announcement.kind) {
    case AnnouncementKind.approach:
    case AnnouncementKind.arrival:
      if (text == 'Now approaching $n.') return 'approach';
      if (text == 'You have arrived at your destination, $n.') {
        return 'destination';
      }
      return null;
    case AnnouncementKind.passed:
      return text == 'You have passed $n.' ? 'passed' : null;
    case AnnouncementKind.overshoot:
      return text ==
              'You have passed your stop. It is alright. Please alight '
                  'here, at $n.'
          ? 'overshoot'
          : null;
  }
}

/// The on-device Sarvam clip pack: `{stationId}__{kind}.wav` files under one
/// language directory.
///
/// Debug delivery is `adb push build/sarvam_clips/en-IN` into the app's
/// external files dir (`clips/en-IN`, the same adb-reachable spot the ride
/// logs live in), which keeps 125 MB of audio out of the APK while store
/// delivery is still an open ADR. A missing pack or a missing single file is
/// a silent device-TTS fallback, never an error.
class ClipLibrary {
  ClipLibrary(this.root);

  final Directory root;

  /// The clip for a station and kind, or null when the file is not there.
  File? clipFor(String stationId, String kind) {
    final file = File('${root.path}${Platform.pathSeparator}'
        '${stationId}__$kind.wav');
    return file.existsSync() ? file : null;
  }
}
