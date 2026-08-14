import 'package:audioplayers/audioplayers.dart' as ap;

/// The future that completes when [player] finishes the sound it is playing.
///
/// EXISTS BECAUSE `audioplayers` LIES ABOUT THE TYPE, and the lie is invisible
/// to the analyzer. `onPlayerComplete` is DECLARED `Stream<void>` and built as
/// `eventStream.where(...)` with no `.map`, so the object at runtime is a
/// `Stream<AudioEvent>`. Awaiting `.first` therefore hands back a runtime
/// `Future<AudioEvent>` wearing a `Future<void>` static type, and
/// `Future.timeout` type-checks its `onTimeout` closure against the RUNTIME
/// type argument.
///
/// THE 14 AUG 2026 RIDE IS WHAT THAT COST. Nine station clips of nine threw
/// `() => Null is not a subtype of () => FutureOr<AudioEvent>`, the caller read
/// it as "played, do not repeat", and the rider heard nothing at Kalyan,
/// Thakurli, Dombivli, Kopar or Diva.
///
/// TWO DETAILS WORTH KEEPING, because neither is guessable from the error:
///
///   - The throw is SYNCHRONOUS, at the `.timeout(...)` call rather than at
///     expiry, so it lands at whatever time `play()` took and looks nothing
///     like a timeout.
///   - `.timeout(duration)` with NO closure is safe. The trap arms only when a
///     closure is passed, which is why two call sites survived for months.
///
/// ONE FUNCTION RATHER THAN THREE MAPPED CALL SITES, deliberately. Disarming
/// the trap three times leaves it armed at site four, and site four is
/// whichever sound someone adds next.
///
/// `ignore()` is applied here so a `play()` that throws before the caller
/// awaits cannot surface an unhandled error later.
Future<void> completionOf(ap.AudioPlayer player) =>
    player.onPlayerComplete.map<void>((_) {}).first..ignore();
