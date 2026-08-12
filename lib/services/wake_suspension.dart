/// Who is allowed to silence the wake ladder, and who is allowed to bring it
/// back.
///
/// TWO INPUTS SHARE ONE MECHANISM, which is why this exists as a type rather
/// than as two lines inside the service. A real call and the rider's own wake
/// toggle both suspend through `WakeEscalation.onCallStateChanged`, and that is
/// the right mechanism for both: silent, but not deaf, still tracking what the
/// train passes, re-orienting on the way back.
///
/// Wired naively they share one flag, and then a call ENDING while the rider
/// had the alarm switched off would resume the ladder and re-arm an alarm they
/// deliberately turned off. That is the silent-alarm failure in reverse: an
/// alarm nobody asked for, on a rider who is awake and now trusts the app less.
///
/// It lives in its own file because `GeofenceChainService` cannot be built in a
/// test (it reaches plugins on construction), and this is the half worth
/// testing. See `wake_suspension_test.dart` for the truth table.
class WakeSuspension {
  const WakeSuspension({required this.suspended, required this.catchUp});

  /// Whether the ladder should be silent right now.
  final bool suspended;

  /// On the way back, whether the rider is owed a report of what they missed.
  ///
  /// TRUE ONLY FOR A CALL. An interruption happened TO them, so the app owes
  /// them the stations that went by. Switching the alarm off is a decision they
  /// made, and every catch-up line in SpokenCopy opens "While you were on your
  /// call", which would be a lie.
  final bool catchUp;

  /// EITHER input suspends; only agreement resumes.
  static WakeSuspension of({
    required bool inRealCall,
    required bool wakeEnabled,
  }) => WakeSuspension(
    suspended: inRealCall || !wakeEnabled,
    catchUp: inRealCall,
  );
}
