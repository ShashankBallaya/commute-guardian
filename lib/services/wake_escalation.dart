import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/journey.dart';
import '../models/station.dart';
import 'announcement_templates.dart';
import 'ride_progress.dart';
import 'spoken_copy.dart';

/// One thing the platform shell must do right now: speak, sound or silence
/// the alarm tone, buzz, or give the ladder up entirely. Sealed so the W3
/// shell's switch over actions stays exhaustive.
sealed class WakeAction {
  const WakeAction();
}

class Speak extends WakeAction {
  const Speak(this.text);
  final String text;
}

/// Ensure the looping alarm tone is playing at [volume]. Idempotent on the
/// shell side by design: restart the loop if something killed it (the iOS
/// shared-session lesson from W1), else just set the volume.
class Tone extends WakeAction {
  const Tone(this.volume);
  final double volume;
}

class StopTone extends WakeAction {
  const StopTone();
}

/// The ladder reached its ceiling unacknowledged: one station past the
/// critical one, the recovery alight point, where RideProgress's overshoot
/// announcement takes over. Escalating further would just be noise chasing
/// a rider who is getting off anyway (locked decision 7).
class HardStop extends WakeAction {
  const HardStop();
}

/// Something the ride log should record, with no sound attached.
///
/// Patterned on `PulseNote`. The engine is platform-free and owns no logger,
/// but a decision NOT to alarm is exactly the kind of silence that looks
/// identical to a working ride unless something writes it down. See
/// [WakeEscalation.maxDeadReckonCoast], whose whole purpose is to withhold a
/// ladder, and which would otherwise withhold it invisibly.
class WakeNote extends WakeAction {
  const WakeNote(this.message);
  final String message;
}

/// Buzz insistently. Honoured on BOTH platforms since 12 Aug 2026
/// (`docs/adr/0003`); the iOS shell used to ignore it.
///
/// The action stays shapeless on purpose. Android controls duration and
/// pattern, iOS has one fixed buzz and can vary only count and cadence, and
/// this engine is platform-free: it says "buzz insistently" and
/// [WakeAlertOutput] decides what that means on the hardware it is holding.
class Vibrate extends WakeAction {
  const Vibrate();
}

/// Pure, platform-free decision engine for the wake escalation ladder.
///
/// Sibling of [RideProgress]: time is passed in rather than read from a
/// clock, so every transition is testable and the class carries no platform
/// risk. It consumes the announcements RideProgress emits (so the two
/// engines always agree on where the train is), decides when to ask the
/// rider to prove they are awake, and escalates while they stay silent.
class WakeEscalation {
  WakeEscalation({
    required this.chain,
    required this.interchangeStationIds,
    required this.destinationStationId,
    this.walkInterchangeStationIds = const {},
    this.language = AppLanguage.english,
  });

  /// Build the engine from the journey it runs for. The critical stations are
  /// exactly what the journey already knows: the interchanges THIS route
  /// requires, then the destination (locked decision 6), in the chain order
  /// the planner emits. See [WindDown.forJourney] for why this is a factory.
  factory WakeEscalation.forJourney(
    Journey journey, {
    AppLanguage language = AppLanguage.english,
  }) => WakeEscalation(
    language: language,
    chain: journey.chain,
    interchangeStationIds: [
      for (final interchange in journey.interchanges) interchange.stationId,
    ],
    destinationStationId: journey.destinationStationId,
    walkInterchangeStationIds: {
      for (final interchange in journey.interchanges)
        if (interchange.walkToStationName != null) interchange.stationId,
    },
  );

  final List<Station> chain;
  final List<String> interchangeStationIds;
  final String destinationStationId;

  /// The interchanges this route reaches ON FOOT, by the station the rider
  /// alights at. Both halves of a walk interchange sit on the chain (the
  /// planner puts them there because the rider passes through each), so the
  /// station immediately after such a target is its OTHER HALF, not a station
  /// past it. At Dadar the two centres are 207 m apart behind 450 m fences, so
  /// a rider standing on the Central platform is already well inside the
  /// Western one: ceilinging there would hard-stop the alarm at the exact
  /// moment the rider still has to get off and cross.
  final Set<String> walkInterchangeStationIds;

  /// What the ladder speaks in. The alarm is the one feature the product
  /// exists for, so its lines go through the same clip-backed templates the
  /// station announcements use: see [WakeLine].
  final AppLanguage language;

  late final SpokenCopy _copy = SpokenCopy(language);

  // Ladder timings from the locked design (decision 7), named so bench
  // tuning is one edit. Same values the W1 spike proved on hardware.
  static const checkInToFirstRung = Duration(seconds: 25);
  static const rungInterval = Duration(seconds: 15);
  static const rungVolumes = [0.3, 0.6, 1.0];

  /// How close, in travel time, the critical station may get before the
  /// check-in fires (decision 5's ETA zone). Sized to fit the whole ladder
  /// ramp ahead of arrival; bench-tuned like the rung timings.
  static const leadTimeS = 90;

  /// Same gate as RideProgress: an accuracy-blackout fix must not feed the
  /// ETA, it would either trigger early or seed a bogus projection.
  static const maxAccuracyM = 150.0;

  /// Below walking pace the distance/speed division explodes into a
  /// meaningless ETA (a train stopped at a signal "arrives" in hours), so
  /// such fixes are skipped rather than misread.
  static const minSpeedMps = 0.5;

  /// How long the dead-reckoning countdown in [onTick] may coast on a single
  /// fix before it stops being evidence.
  ///
  /// THE ETA IS A STRAIGHT LINE OVER ONE INSTANT'S SPEED, and both terms decay
  /// the moment fixes stop. Rail distance exceeds the straight line, and a
  /// train sheds that speed at every station in between. Neither error is
  /// visible to a countdown that just subtracts wall-clock seconds, so the
  /// longer it coasts the more confidently wrong it gets.
  ///
  /// SIZED FROM THE 21 AUG 2026 RIDE, where it ran unbounded. The 3T lost GPS
  /// 15.46 km from Kalyan while doing 21.9 m/s, which seeded a 706 s
  /// countdown. It then coasted 643 s through a 10.7 minute blackout and
  /// started the ladder 10.5 km and 12.6 minutes short of the stop. The rider
  /// was woken near Diva, acked, and THAT ACK RESOLVED KALYAN: the cursor
  /// advanced, so the real alarm could never fire. An early ladder does not
  /// merely annoy, it SPENDS the alarm. That is why this bound is safety, not
  /// polish.
  ///
  /// 180 s still covers what dead reckoning is for, a blackout in the final
  /// approach: it admits any last fix whose own ETA was under 270 s, which is
  /// [leadTimeS] plus the coast. Beyond that the ladder waits for a real
  /// station event, and [WakeNote] says in the log that it did.
  static const maxDeadReckonCoast = Duration(seconds: 180);

  /// The critical stations (locked decision 6: the rider's destination plus
  /// the interchanges THEIR route requires, nothing else), one ladder each,
  /// armed in chain order. [interchangeStationIds] comes from the planner
  /// already ordered, the same invariant RideProgress trusts of [chain].
  late final List<String> _targets = [
    ...interchangeStationIds,
    destinationStationId,
  ];

  /// Index into [_targets] of the ladder currently armed; past the end once
  /// every critical station has been resolved (acknowledged or ceilinged).
  int _cursor = 0;

  bool _ladderLive = false;
  int _rung = 0;
  DateTime? _nextTransitionAt;

  /// Whether the current blackout has already had its [WakeNote]. Cleared by
  /// the next usable fix, so a ride that blacks out twice says so twice.
  bool _deadReckonAbandoned = false;

  /// Seed for the dead-reckoning timer (decision 5's blackout leg): the ETA
  /// computed at the last usable fix and when that fix landed, so [onTick]
  /// can keep counting down after fixes stop arriving.
  DateTime? _lastFixAt;
  double? _lastEtaS;

  /// On a call means awake, not asleep (locked decision 8): outputs are
  /// suspended while true, but station events keep being ingested so call
  /// end can re-orient the rider to where the train is NOW.
  bool _inCall = false;

  /// When the suspension began, for the self-resume below.
  DateTime? _suspendedAt;

  /// How long a suspension may run without an ended event before the
  /// engine resumes on its own. iOS does not guarantee the
  /// interruption-ended event (on the 18 Jul ride the Music app seized
  /// the session, no ended ever came, and the ladder stayed dead for the
  /// rest of the ride). The asymmetry picks the timeout's side: a false
  /// resume during a real long call costs an awake rider one ack tap,
  /// while a ladder that never comes back costs a sleeping rider their
  /// stop.
  static const interruptionResumeTimeout = Duration(minutes: 3);

  /// Whether the ladder was mid-flight when the call suspended it, so call
  /// end knows to resume rather than wait for a trigger that already fired.
  bool _suspendedLadder = false;

  /// Chain stations announced while the call was live, in order, for the
  /// hang-up catch-up ("the train passed X and Y").
  final List<String> _passedDuringCall = [];

  /// Whether a ladder is currently asking to be acknowledged. The shell
  /// mirrors this into the native media session (earphone taps route to us
  /// only while true), the UI's "I'm awake" button, and the audio-session
  /// hold that keeps the tone alive on iOS. False while a call suspends
  /// the ladder: mid-call the rider needs none of those.
  bool get isLadderLive => _ladderLive;

  /// Which rung the ladder is on, 1-based, or 0 before it starts.
  ///
  /// Exposed for the wake alert screen, which steps its glow with the sound so
  /// a rider who surfaces mid-ladder can see how long it has been shouting.
  int get rung => _rung;

  /// False once the ladder has reached full volume and is holding there.
  ///
  /// THERE IS NO TOTAL TO SHOW, deliberately: [_rung] keeps incrementing past
  /// [rungVolumes] while the volume holds, and the ladder ends when the rider
  /// answers or the train passes the ceiling, never on a count. The screen
  /// states that contract in words rather than printing "of 3".
  bool get isClimbing => _rung < rungVolumes.length;

  bool get _hasTarget => _cursor < _targets.length;
  int get _targetIndex => chain.indexWhere((s) => s.id == _targets[_cursor]);
  Station get _target => chain[_targetIndex];
  bool get _targetIsDestination => _targets[_cursor] == destinationStationId;

  /// Chain index of the station whose arrival hard-stops the current ladder:
  /// the first station that genuinely means "you have gone too far". Normally
  /// the next one along, but a walk interchange's own other half is skipped
  /// (see [walkInterchangeStationIds]). Negative when there is no target, and
  /// may run past the chain end, which both callers already bounds-check.
  int get _ceilingIndex {
    final targetIndex = _targetIndex;
    if (targetIndex < 0) return -1;
    return targetIndex +
        (walkInterchangeStationIds.contains(_targets[_cursor]) ? 2 : 1);
  }

  /// A station event from RideProgress. The check-in fires when the train
  /// reaches the station one before the critical one (pre-emptive trigger,
  /// locked decision 1).
  List<WakeAction> onStationEvent(Announcement announcement, DateTime now) {
    if (!_hasTarget) return const [];

    // An approach ping means the train is STILL SHORT of the station
    // (outer fence, ~1 km out). Treating it as reached would start ladders
    // early, silence one at the ceiling a minute before the recovery
    // point, and mis-tell hang-up that a mid-call stop was reached. Only
    // arrival/passed/overshoot move the train here; the ETA zone is the
    // honest early signal.
    //
    // ONE EXCEPTION, and it is the whole fix for a one-station journey.
    // The normal trigger below arms on the station BEFORE the target. When
    // the target sits at chain index 1, that station is the ORIGIN, and
    // RideProgress announces the origin on the ride's very first fix, so a
    // Shahad to Ambivli rider had the full ladder climbing the instant they
    // pressed Start. A false alarm is the one thing that teaches a rider to
    // ignore the voice meant to wake them.
    //
    // The target's own approach fence is the only forward-looking station
    // event such a journey has, and it always exists: Journey.approachRadiusM
    // gives 1000 m to the destination and 1200 m to every interchange, which
    // is precisely the set this ladder ever targets. It is not used for
    // longer journeys, where the station before the target is a real station
    // and the original objection stands untouched.
    if (announcement.kind == AnnouncementKind.approach) {
      if (!_inCall &&
          !_ladderLive &&
          _targetIndex == 1 &&
          announcement.stationId == _targets[_cursor]) {
        return _startLadder(now);
      }
      return const [];
    }

    if (_inCall) {
      // Suspended means silent, not deaf: the train keeps moving during
      // the call and hang-up must know what it passed.
      if (chain.any((s) => s.id == announcement.stationId)) {
        _passedDuringCall.add(announcement.stationId);
      }
      return const [];
    }

    final targetIndex = _targetIndex;

    // Ceiling: one station past the critical one hard-stops the ladder,
    // acknowledged or not.
    final ceilingIndex = _ceilingIndex;
    if (_ladderLive &&
        ceilingIndex > 0 &&
        ceilingIndex < chain.length &&
        announcement.stationId == chain[ceilingIndex].id) {
      final toneWasPlaying = _rung >= 1;
      _standDown();
      return [if (toneWasPlaying) const StopTone(), const HardStop()];
    }

    // targetIndex > 1, NOT > 0: at 1 the station before the target is the
    // origin, and that ladder is handled by the approach branch above. See
    // the comment there for why the origin can never be a trigger.
    if (!_ladderLive &&
        targetIndex > 1 &&
        announcement.stationId == chain[targetIndex - 1].id) {
      return _startLadder(now);
    }
    return const [];
  }

  /// One raw GPS fix. Only ever starts a ladder (the ETA leg of decision
  /// 5's first-of-three trigger, which covers a jumped trigger fence); rung
  /// progression stays [onTick]'s job.
  List<WakeAction> onFix({
    required double lat,
    required double lng,
    required double accuracyM,
    required double speedMps,
    required DateTime now,
  }) {
    if (!_hasTarget || _ladderLive) return const [];
    if (accuracyM > maxAccuracyM) return const [];
    if (speedMps < minSpeedMps) return const [];

    final etaS = _distanceM(lat, lng, _target.lat, _target.lng) / speedMps;
    _lastFixAt = now;
    _lastEtaS = etaS;
    // A usable fix ends the blackout, so the next one may be reported.
    _deadReckonAbandoned = false;
    // Mid-call the seed still updates (silent, not deaf, so hang-up
    // re-syncs against the freshest position), but no ladder starts into
    // the rider's conversation.
    if (!_inCall && etaS <= leadTimeS) {
      return _startLadder(now);
    }
    return const [];
  }

  List<WakeAction> _startLadder(DateTime now) {
    _ladderLive = true;
    _rung = 0;
    _nextTransitionAt = now.add(checkInToFirstRung);
    return [Speak(_checkInText())];
  }

  String _checkInText() =>
      (_targetIsDestination ? WakeLine.checkIn : WakeLine.checkInChange).render(
        _target.nameIn(language),
        language: language,
      );

  // The doubled "Wake up!" is owner-approved aggressive copy. It lives in
  // announcement_templates.dart with the station lines, because the same
  // wording is what tool/build_clip_pack.py cut the wake clips from and a
  // hand-kept copy here is exactly the drift that file exists to stop.
  String _firmText() =>
      (_targetIsDestination ? WakeLine.wakeUpStop : WakeLine.wakeUpChange)
          .render(_target.nameIn(language), language: language);

  /// Resolves the current target and arms the next one. Every ladder ends
  /// here, whichever way it ends.
  void _standDown() {
    _cursor++;
    _ladderLive = false;
    _rung = 0;
    _nextTransitionAt = null;
    // An ETA computed against the old target must not count down toward
    // the next one.
    _lastFixAt = null;
    _lastEtaS = null;
  }

  /// Great-circle distance in metres between two lat/lng points (haversine).
  /// Duplicated from RideProgress on purpose: each engine stays a
  /// self-contained pure module, the shape both already take.
  static double _distanceM(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  /// A phone call started or ended (the shell listens to the audio-session
  /// interruption stream). Starting one silences and freezes a live ladder.
  ///
  /// ALSO THE RIDER'S OWN WAKE TOGGLE since 12 Aug 2026, which suspends through
  /// this same door because it wants exactly the same behaviour: silent but not
  /// deaf, still tracking what the train passes, re-orienting on the way back.
  /// What it does not want is the catch-up, which is what [catchUp] is for.
  ///
  /// [catchUp] false means RESUME FOR WHAT IS AHEAD, and say nothing about what
  /// went by. Two reasons, and the second is the real one:
  ///
  ///   - The copy would lie. Every catch-up line in [SpokenCopy] opens "While
  ///     you were on your call", and a rider who switched off their own alarm
  ///     was not on a call.
  ///   - The semantics differ. A call is an interruption that happened TO the
  ///     rider, so the app owes them what they missed. Switching the alarm off
  ///     is a decision they made, and re-arming it is a decision about the rest
  ///     of the journey rather than a request for a report. If they slept past
  ///     their stop with it off, RideProgress's overshoot announcement still
  ///     speaks, in all three languages, untouched by any of this.
  List<WakeAction> onCallStateChanged({
    required bool inCall,
    required DateTime now,
    bool catchUp = true,
  }) {
    if (inCall) {
      if (_inCall) return const [];
      _inCall = true;
      _suspendedAt = now;
      _suspendedLadder = _ladderLive;
      _passedDuringCall.clear();
      final toneWasPlaying = _ladderLive && _rung >= 1;
      _ladderLive = false;
      _rung = 0;
      _nextTransitionAt = null;
      return [if (toneWasPlaying) const StopTone()];
    }
    if (!_inCall) return const [];
    _inCall = false;
    _suspendedAt = null;
    // Forgetting what went by is the whole of "no catch-up": every branch
    // below reads this list, so clearing it here makes the firm-rung path and
    // the spoken catch-up disappear together, which is correct. A rider
    // re-arming gets the ordinary ladder for the stops still ahead.
    if (!catchUp) _passedDuringCall.clear();

    final targetIndex = _targetIndex;

    // The stop itself went by during the call: no lead is left to be
    // gentle with, so skip the ramp and open at a firm rung (decision 8's
    // "straight into the firm wake rung"). The ladder stays live at full
    // so silence keeps hammering and an ack stands it down as usual. The
    // copy must not overclaim: if the ceiling also went by, the rider is
    // provably PAST the stop, not at it.
    if (_passedDuringCall.contains(_targets[_cursor])) {
      _ladderLive = true;
      _rung = rungVolumes.length;
      _nextTransitionAt = now.add(rungInterval);
      final ceilingIndex = _ceilingIndex;
      final pastCeiling =
          ceilingIndex > 0 &&
          ceilingIndex < chain.length &&
          _passedDuringCall.contains(chain[ceilingIndex].id);
      return [
        Tone(rungVolumes.last),
        const Vibrate(),
        Speak(
          pastCeiling
              ? _copy.postCallPassedStop(_target.nameIn(language))
              : _copy.postCallReachedStop(_target.nameIn(language)),
        ),
      ];
    }

    // Re-orientation to now, not a history replay (decision 8): if the
    // trigger station went by during the call (or the ladder was already
    // suspended mid-flight), tell the rider what the call swallowed and arm
    // the ladder from hang-up. The catch-up doubles as the check-in.
    final triggerPassedDuringCall =
        targetIndex > 1 &&
        _passedDuringCall.contains(chain[targetIndex - 1].id);
    if (triggerPassedDuringCall || _suspendedLadder) {
      _suspendedLadder = false;
      final actions = _startLadder(now);
      if (_passedDuringCall.isEmpty) return actions;
      final names = _passedDuringCall
          .map((id) => chain.firstWhere((s) => s.id == id).nameIn(language))
          .toList();
      return [
        Speak(
          _copy.postCallCatchUp(
            stations: _copy.joinNames(names),
            checkIn: _checkInText(),
          ),
        ),
      ];
    }
    return const [];
  }

  /// Any proof of wakefulness: a media-remote tap forwarded by the shell,
  /// or the on-screen I'm-awake button. Stands the ladder down at whatever
  /// stage it is on.
  List<WakeAction> acknowledge(DateTime now) {
    if (!_ladderLive) return const [];
    // The tone only starts at rung 1; an ack still in the check-in window
    // has nothing to silence.
    final toneWasPlaying = _rung >= 1;
    _standDown();
    return [
      if (toneWasPlaying) const StopTone(),
      Speak(FixedLine.goodAwake.render(language: language)),
    ];
  }

  /// A clock tick from the shell. Climbs a live, unacknowledged ladder to
  /// its next rung once that rung's time has come.
  List<WakeAction> onTick(DateTime now) {
    if (_inCall) {
      // Self-resume: the ended event this suspension is waiting for may
      // never arrive (see interruptionResumeTimeout). Delivering the
      // synthetic call-end here runs the same catch-up logic a real
      // hang-up gets, firm rung included if the stop went by.
      final suspendedAt = _suspendedAt;
      if (suspendedAt != null &&
          !now.isBefore(suspendedAt.add(interruptionResumeTimeout))) {
        return onCallStateChanged(inCall: false, now: now);
      }
      return const [];
    }

    // Dead-reckoning: no ladder yet, but the countdown seeded by the last
    // usable fix keeps running through a blackout. A train that was 200
    // seconds from the stop when GPS died is still arriving.
    //
    // BOUNDED SINCE 21 AUG 2026. The seed is only evidence while it is fresh;
    // see [maxDeadReckonCoast] for the ride that proved what happens when it
    // is not. Past the bound the ladder waits for a real station event, which
    // is what the other two legs of the trigger are for.
    if (!_ladderLive && _hasTarget && _lastFixAt != null) {
      final staleness = now.difference(_lastFixAt!);
      if (staleness > maxDeadReckonCoast) {
        // Once per blackout, on the crossing, not on every tick: this path
        // runs at tick cadence for as long as the fixes stay away, and a line
        // per tick would bury the ride log it is meant to explain.
        if (!_deadReckonAbandoned) {
          _deadReckonAbandoned = true;
          return [
            WakeNote(
              'WAKE dead reckoning abandoned: last usable fix '
              '${staleness.inSeconds}s old, projection no longer trusted. '
              'The ladder now waits for a station event.',
            ),
          ];
        }
        return const [];
      }
      final remainingS = _lastEtaS! - staleness.inSeconds;
      if (remainingS <= leadTimeS) {
        return _startLadder(now);
      }
    }

    if (!_ladderLive ||
        _nextTransitionAt == null ||
        now.isBefore(_nextTransitionAt!)) {
      return const [];
    }
    _rung++;
    // The next rung is due one interval after this one was SCHEDULED, not
    // after the tick that happened to observe it: a late tick must not let
    // the whole ladder drift later and later.
    _nextTransitionAt = _nextTransitionAt!.add(rungInterval);
    final volume = _rung <= rungVolumes.length
        ? rungVolumes[_rung - 1]
        : rungVolumes.last;
    if (_rung == 1) {
      return [Tone(volume), Speak(_firmText())];
    }
    return [Tone(volume), const Vibrate()];
  }
}
