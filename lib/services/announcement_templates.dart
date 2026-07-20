/// The en-IN sentences a station announcement is built from, in one place.
///
/// Three things have to agree on this wording byte for byte: the engines
/// that speak it (RideProgress, WakeEscalation), the clip lookup that
/// decides a Sarvam clip may stand in for an utterance, and
/// tool/build_clip_pack.py, which cut the clips from the same wording. It
/// lived in all three by hand until a review found the two overshoot
/// copies wrapping at different points, which made byte-identity
/// impossible to check by eye. The Dart side now renders from here, and
/// test/announcement_templates_test.dart pins every sentence to a literal
/// so the Python tool has one documented contract to match.
enum ClipKind {
  approach('approach'),
  passed('passed'),
  overshoot('overshoot'),
  destination('destination');

  const ClipKind(this.fileSuffix);

  /// The clip pack's filename fragment: `{stationId}__{fileSuffix}.wav`.
  final String fileSuffix;

  /// The en-IN sentence for a station, exactly as the device TTS floor
  /// speaks it and exactly as the clip was cut.
  String render(String stationName) => switch (this) {
        ClipKind.approach => 'Now approaching $stationName.',
        ClipKind.passed => 'You have passed $stationName.',
        ClipKind.overshoot =>
          'You have passed your stop. It is alright. Please alight here, '
              'at $stationName.',
        ClipKind.destination =>
          'You have arrived at your destination, $stationName.',
      };
}
