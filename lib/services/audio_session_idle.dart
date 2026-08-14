/// Whether NOTHING OF OURS is making noise, so the audio session may be handed
/// back and the rider's music can come up again.
///
/// A free function, and deliberately not a method on the service. On iOS the
/// audio context is the app-wide shared AVAudioSession, so every sound this app
/// makes shares one release decision, and that decision has now been got wrong
/// three times by three different sounds:
///
///   - speech has always paired `setActive(true)` with a release;
///   - clips did not, until the 13 Aug 2026 ride (`befaca4`);
///   - the pulse chime did not, until the 14 Aug 2026 ride.
///
/// Each of those was a whole ride of quiet music. The service that owns the
/// counters cannot be built under the test binding, so keeping the rule out
/// here is what lets it have a real test instead of a source guard.
///
/// [wakeLadderLive] is NOT a counter and must not become one. The ladder holds
/// the session across the gaps BETWEEN its rungs, when nothing is sounding at
/// all: deactivating in one of those gaps is what silenced the looping alarm
/// tone the moment rung 1's speech finished, on the 15 Jul 2026 iPhone bench.
/// The ladder releases the session itself when it stands down.
bool audioSessionIsIdle({
  required int pendingSpeaks,
  required int pendingClips,
  required int pendingPulses,
  required bool wakeLadderLive,
}) =>
    pendingSpeaks == 0 &&
    pendingClips == 0 &&
    pendingPulses == 0 &&
    !wakeLadderLive;
