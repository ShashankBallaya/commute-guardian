/// One thing the shell must do for the pulse. Sealed so the switch stays
/// exhaustive, the same contract [WindDownAction] uses.
sealed class PulseAction {
  const PulseAction();
}

/// Play the chime, and buzz if the rider asked for that.
class PulseChime extends PulseAction {
  const PulseChime();
}

/// A diagnostic for the ride log, never sounded.
///
/// Exists for the reason [WindDownNote] does: SILENCE HAS NO CAUSE IN A LOG. A
/// pulse that stopped because a ladder went live looks exactly like a pulse
/// that was never switched on, and after the 22 Jul ride that ambiguity cost a
/// session of guessing and one confidently wrong root cause.
class PulseNote extends PulseAction {
  const PulseNote(this.reason);
  final String reason;
}

/// Pocket Pulse's decision engine: WHEN to chime, never how.
///
/// Pure, platform-free, time passed in and actions out, exactly like
/// [RideProgress], [WakeEscalation] and [WindDown]. It owns no timer: the
/// service already ticks every 5 seconds for the other engines and this rides
/// that, so the whole feature adds zero wakeups. See docs/design/pocket-pulse.md.
///
/// THE RANK IS THE DESIGN, and it is asymmetric on purpose:
///
///   - Against an ANNOUNCEMENT the pulse DEFERS. An announcement is bounded, a
///     few seconds, so waiting is honest and the chime still lands.
///   - Against a WAKE LADDER it DROPS, and does not catch up afterwards. A
///     ladder is unbounded (it climbs until acknowledged), so deferring would
///     stack stale pulses onto the exact moment the rider silences their alarm.
///     A rider who just acknowledged an alarm is holding the phone and needs no
///     reassurance that it is in their pocket.
///   - Against a CALL it drops for the same reason, and because the handover's
///     own rule is that this app never interrupts calls.
///
/// The owner ratified that order on 30 Jul as Wake-up > Announcement > Pulse.
class PocketPulse {
  PocketPulse({int? intervalS, DateTime? startedAt})
    : _intervalS = (intervalS != null && intervalS > 0) ? intervalS : null {
    if (_intervalS != null && startedAt != null) {
      _nextDueAt = startedAt.add(Duration(seconds: _intervalS!));
    }
  }

  /// Seconds between chimes, or null when the pulse is off. Comes from
  /// [AppSettings.pulseIntervalSeconds], which already folds crowd mode in.
  int? _intervalS;

  /// When the next chime is due, or null when off.
  ///
  /// THE CADENCE IS ANCHORED TO THE SCHEDULE, not to the last chime. Advancing
  /// by whole intervals from the due time means a chime delayed by a long
  /// announcement does not push every later chime along with it, so a rider on
  /// a 3 minute setting keeps getting one roughly every 3 minutes rather than
  /// watching the cadence drift later all ride.
  DateTime? _nextDueAt;

  /// When the currently-deferred slot was originally due, or null when nothing
  /// is waiting on the announcer.
  DateTime? _deferredSince;

  /// How long a chime will wait for the announcer before its slot is abandoned.
  ///
  /// Bench-tunable, like every threshold in this project. The reasoning: the
  /// longest announcement templates run about 8 seconds and an interchange
  /// script plus a queued clip can chain past that, so a few seconds is too
  /// eager; but a chime that arrives a full minute late is answering a question
  /// the rider stopped asking, and the next slot is usually closer than that
  /// anyway.
  static const deferralCap = Duration(seconds: 60);

  bool _ladderLive = false;
  bool _inCall = false;

  bool get _suppressed => _ladderLive || _inCall;

  /// Whether a chime is currently waiting for the announcer to finish. Exposed
  /// for tests and the ride log, not for decisions.
  bool get isDeferred => _deferredSince != null;

  /// When the next chime is due, or null when the pulse is off.
  DateTime? get nextDueAt => _nextDueAt;

  /// Start, stop or retime the pulse, including MID-RIDE.
  ///
  /// RE-ANCHORS from [now] rather than keeping the old schedule. A rider who
  /// just switched crowd mode on wants the tighter cadence to start being true
  /// immediately, not after the old interval drains; and one who just turned
  /// the pulse on should hear it one interval later, not at whatever moment the
  /// previous schedule happened to land on.
  ///
  /// A call with the interval unchanged is a no-op, so the settings write-through
  /// path cannot accidentally reset the cadence on every rebuild.
  List<PulseAction> setInterval(int? seconds, DateTime now) {
    final next = (seconds != null && seconds > 0) ? seconds : null;
    if (next == _intervalS) return const [];
    _intervalS = next;
    _deferredSince = null;
    if (next == null) {
      _nextDueAt = null;
      return const [PulseNote('pulse off')];
    }
    _nextDueAt = now.add(Duration(seconds: next));
    return [PulseNote('pulse every ${next}s, next at ${_hhmmss(_nextDueAt!)}')];
  }

  /// The wake ladder started or stood down.
  List<PulseAction> onWakeLadder(bool live, DateTime now) {
    if (live == _ladderLive) return const [];
    _ladderLive = live;
    return _suppressionNote(
      live ? 'suppressed: wake ladder live' : 'resumed: ladder stood down',
      now,
    );
  }

  /// The rider took or ended a call.
  List<PulseAction> onCallState(bool inCall, DateTime now) {
    if (inCall == _inCall) return const [];
    _inCall = inCall;
    return _suppressionNote(
      inCall ? 'suppressed: call in progress' : 'resumed: call ended',
      now,
    );
  }

  /// A deferred chime cannot survive a suppression: the announcer it was
  /// waiting for is now the least of its problems, and letting it through the
  /// moment the ladder stands down is precisely the catch-up burst this engine
  /// exists to prevent.
  List<PulseAction> _suppressionNote(String reason, DateTime now) {
    if (_suppressed) _deferredSince = null;
    return _intervalS == null ? const [] : [PulseNote('pulse $reason')];
  }

  /// One tick from the service, every 5 seconds.
  ///
  /// [announcerBusy] is passed per tick rather than held as state because it is
  /// a fact about the world right now (the TTS queue and the clip chain), and
  /// an engine that cached it would be a second place that could be wrong about
  /// whether this app is currently talking.
  List<PulseAction> onTick(DateTime now, {required bool announcerBusy}) {
    final interval = _intervalS;
    final dueAt = _nextDueAt;
    if (interval == null || dueAt == null) return const [];

    // Suppressed: the slot is LOST, not banked. Walking the schedule past now
    // is what guarantees no catch-up burst when the ladder stands down.
    if (_suppressed) {
      _advancePast(now, interval);
      return const [];
    }

    if (now.isBefore(dueAt)) return const [];

    if (announcerBusy) {
      _deferredSince ??= dueAt;
      if (now.difference(_deferredSince!) < deferralCap) return const [];
      // Waited a full minute. Abandon the slot rather than interrupting the
      // moment the announcer finally stops, which by then is a chime arriving
      // in the middle of whatever the rider is now paying attention to.
      //
      // This IS logged, unlike an ordinary suppressed slot. The design says
      // notes fire on suppression transitions only so a crowd-mode ride cannot
      // spam the log, and that reasoning holds for the ladder case, which drops
      // a slot every interval for minutes. A full minute of continuous
      // announcement is rare enough to be worth a line when it happens.
      _deferredSince = null;
      _advancePast(now, interval);
      return const [PulseNote('pulse slot abandoned: announcer busy 60s')];
    }

    _deferredSince = null;
    _advancePast(now, interval);
    return const [PulseChime()];
  }

  /// Discards every slot that has already come due, leaving the next one in
  /// the future.
  ///
  /// The loop is what COLLAPSES missed slots: a deferral or a suppression
  /// spanning several intervals must produce ONE chime and then resume the
  /// normal cadence, never a burst of the ones that were owed.
  ///
  /// THE CONDITION IS "ALREADY DUE", NOT "ALWAYS ADVANCE ONE", and the first
  /// draft got that wrong. It added an interval on every suppressed tick, so a
  /// ladder climbing for five minutes walked the schedule sixty intervals into
  /// the future and the pulse stayed silent long after the alarm was
  /// acknowledged. The tests caught it; a rider would have reported it as the
  /// pulse "just stopping" and it would have been miserable to find.
  void _advancePast(DateTime now, int intervalS) {
    final step = Duration(seconds: intervalS);
    while (!_nextDueAt!.isAfter(now)) {
      _nextDueAt = _nextDueAt!.add(step);
    }
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}
