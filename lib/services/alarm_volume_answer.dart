/// What the ladder may remember from the native side's answer, and therefore
/// what it is allowed to put back on the rider's phone afterwards.
///
/// A FREE FUNCTION BECAUSE THE CALL SITE CANNOT BE TESTED. `raiseAlarmVolume`
/// opens with `if (!Platform.isIOS) return null`, so every test of it on a
/// desktop host passes without reaching the logic. Four such tests were written
/// on 14 Aug 2026 and all four passed against code that could not run.
///
/// THE FAULT THIS EXISTS TO STOP, from the 14 Aug 2026 bench. Dart used to take
/// its own reading of the volume to decide what to remember, while the native
/// side took a second reading to decide what to do, and the two disagreed. The
/// damage was a phone at 85 percent, never raised by us, dropped to 65.
/// Lowering a rider's alarm volume is the exact fault the whole feature exists
/// to prevent.
///
/// STILL BROKEN UPSTREAM OF HERE, and this file cannot fix it. Later that
/// evening the ladder read 65 percent, four samples running, while the slider
/// was at 90. This function faithfully remembers whatever native measured, and
/// native is still measuring the wrong number. See AppDelegate's
/// `raiseAlarmVolume` for the category hypothesis and what it owes a bench.
///
/// So there is ONE reading now, taken natively after activation, and this is
/// the only thing allowed to interpret it. `raisedFrom` absent means the slider
/// never moved, and absent must become null rather than any number at all.
double? volumeTakenFrom(Map<String, Object?>? answer) {
  final raisedFrom = answer?['raisedFrom'];
  // `is num` rather than `as double?`: a method channel can hand back an int
  // for a whole value, and a cast would throw where a missing key returns null,
  // which would turn a rider already loud enough into a crash.
  if (raisedFrom is! num) return null;
  final value = raisedFrom.toDouble();
  if (value.isNaN || value < 0) return null;
  return value.clamp(0.0, 1.0);
}
