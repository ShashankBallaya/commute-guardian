import 'dart:math' as math;

import '../models/station.dart';
import 'ride_progress.dart';

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

/// Android-only bonus layer; the iOS shell ignores it (background haptics
/// are forbidden there, audio is the primary channel on both platforms).
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
  });

  final List<Station> chain;
  final List<String> interchangeStationIds;
  final String destinationStationId;

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

  /// Seed for the dead-reckoning timer (decision 5's blackout leg): the ETA
  /// computed at the last usable fix and when that fix landed, so [onTick]
  /// can keep counting down after fixes stop arriving.
  DateTime? _lastFixAt;
  double? _lastEtaS;

  /// On a call means awake, not asleep (locked decision 8): outputs are
  /// suspended while true, but station events keep being ingested so call
  /// end can re-orient the rider to where the train is NOW.
  bool _inCall = false;

  /// Whether the ladder was mid-flight when the call suspended it, so call
  /// end knows to resume rather than wait for a trigger that already fired.
  bool _suspendedLadder = false;

  /// Chain stations announced while the call was live, in order, for the
  /// hang-up catch-up ("the train passed X and Y").
  final List<String> _passedDuringCall = [];

  bool get _hasTarget => _cursor < _targets.length;
  int get _targetIndex =>
      chain.indexWhere((s) => s.id == _targets[_cursor]);
  Station get _target => chain[_targetIndex];
  bool get _targetIsDestination => _targets[_cursor] == destinationStationId;

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
    if (announcement.kind == AnnouncementKind.approach) return const [];

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
    if (_ladderLive &&
        targetIndex >= 0 &&
        targetIndex + 1 < chain.length &&
        announcement.stationId == chain[targetIndex + 1].id) {
      final toneWasPlaying = _rung >= 1;
      _standDown();
      return [
        if (toneWasPlaying) const StopTone(),
        const HardStop(),
      ];
    }

    if (!_ladderLive &&
        targetIndex > 0 &&
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

    final etaS =
        _distanceM(lat, lng, _target.lat, _target.lng) / speedMps;
    _lastFixAt = now;
    _lastEtaS = etaS;
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

  String _checkInText() {
    final what = _targetIsDestination
        ? 'Your stop, ${_target.name},'
        : 'Your train change at ${_target.name}';
    return '$what is next. Tap your earphones, or press the I am awake '
        'button, to show you are awake.';
  }

  String _firmText() => _targetIsDestination
      ? 'Wake up. Your stop, ${_target.name}, is next.'
      : 'Wake up. Your train change at ${_target.name} is next.';

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
  static double _distanceM(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  /// A phone call started or ended (the shell listens to the audio-session
  /// interruption stream). Starting one silences and freezes a live ladder.
  List<WakeAction> onCallStateChanged({
    required bool inCall,
    required DateTime now,
  }) {
    if (inCall) {
      if (_inCall) return const [];
      _inCall = true;
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
      final ceilingIndex = _targetIndex + 1;
      final pastCeiling = ceilingIndex < chain.length &&
          _passedDuringCall.contains(chain[ceilingIndex].id);
      return [
        Tone(rungVolumes.last),
        const Vibrate(),
        Speak(
          pastCeiling
              ? 'While you were on your call, the train passed your stop, '
                  '${_target.name}. Please get off the train now.'
              : 'While you were on your call, the train reached your stop, '
                  '${_target.name}. Get off the train now.',
        ),
      ];
    }

    // Re-orientation to now, not a history replay (decision 8): if the
    // trigger station went by during the call (or the ladder was already
    // suspended mid-flight), tell the rider what the call swallowed and arm
    // the ladder from hang-up. The catch-up doubles as the check-in.
    final triggerPassedDuringCall = targetIndex > 0 &&
        _passedDuringCall.contains(chain[targetIndex - 1].id);
    if (triggerPassedDuringCall || _suspendedLadder) {
      _suspendedLadder = false;
      final actions = _startLadder(now);
      if (_passedDuringCall.isEmpty) return actions;
      final names = _passedDuringCall
          .map((id) => chain.firstWhere((s) => s.id == id).name)
          .toList();
      return [
        Speak(
          'While you were on your call, the train passed '
          '${_joinWithAnd(names)}. ${_checkInText()}',
        ),
      ];
    }
    return const [];
  }

  static String _joinWithAnd(List<String> names) {
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} '
        'and ${names.last}';
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
      const Speak('Good, you are awake.'),
    ];
  }

  /// A clock tick from the shell. Climbs a live, unacknowledged ladder to
  /// its next rung once that rung's time has come.
  List<WakeAction> onTick(DateTime now) {
    if (_inCall) return const [];

    // Dead-reckoning: no ladder yet, but the countdown seeded by the last
    // usable fix keeps running through a blackout. A train that was 200
    // seconds from the stop when GPS died is still arriving.
    if (!_ladderLive && _hasTarget && _lastFixAt != null) {
      final remainingS =
          _lastEtaS! - now.difference(_lastFixAt!).inSeconds;
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
