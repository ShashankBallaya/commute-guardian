import 'dart:math' as math;

import '../models/station.dart';
import 'ride_progress.dart';

/// One thing the platform shell must do for the wind-down: speak a line, or
/// end Travel Mode. Sealed so the shell's switch stays exhaustive. Named
/// with the WindDown prefix because the service imports this alongside
/// WakeEscalation's own Speak.
sealed class WindDownAction {
  const WindDownAction();
}

class WindDownSpeak extends WindDownAction {
  const WindDownSpeak(this.text);
  final String text;
}

/// End Travel Mode now. The shell runs the normal stop path, so the
/// farewell line and the full teardown come with it.
class WindDownEnd extends WindDownAction {
  const WindDownEnd();
}

/// Pure, platform-free decision engine for the post-arrival auto-off.
///
/// Sibling of RideProgress and WakeEscalation: time and fixes are passed
/// in, outputs are data. It waits for proof the rider actually alighted
/// and then WALKED AWAY from the point where the train stopped, and only
/// then starts the 60 second auto-off countdown. A rider carried past
/// their stop asleep moves away at TRAIN speed, so the countdown never
/// starts and the overshoot net stays alive.
///
/// The walk is measured from the alight anchor (where the train stopped),
/// NOT from the destination's fence edge: on the 18 Jul ride the owner
/// walked out of Kalyan for ten minutes without ever leaving its 500 m
/// fence, and the fence-exit rule never fired. Big stations make the fence
/// unreachable on foot in any reasonable time; the anchor is reachable by
/// definition.
class WindDown {
  WindDown({required this.destination, this.overshootStations = const []})
      : _exitStation = destination;

  final Station destination;

  /// The terminus pins for this journey, the stations a rider carried past
  /// the destination is told to alight at. Needed here (not just in
  /// RideProgress) because reaching one MOVES the exit watch to it: see
  /// [onStationEvent].
  final List<Station> overshootStations;

  /// The station the exit watch is currently anchored to. Starts as the
  /// destination and moves to an overshoot pin when the rider is carried
  /// past. Everything positional keys off this, never off [destination]
  /// directly, so the rider who overshot is measured at the platform they
  /// actually stand on.
  Station _exitStation;

  /// How long after the platform exit is detected Travel Mode ends on its
  /// own (the handover's WIND_DOWN countdown).
  static const countdown = Duration(seconds: 60);

  /// How much time the [Extend] action buys, measured from the press.
  static const extension = Duration(minutes: 10);

  /// Consecutive qualifying fixes required before the exit counts. One
  /// noisy fix must never end a ride. Bench-tunable, like all of these.
  static const exitFixesRequired = 2;

  /// Above this the rider is not on foot; a departing or crawling train
  /// must not read as a platform exit.
  static const walkingSpeedMaxMps = 2.5;

  /// At or below this the train (or the rider) is standing still. The
  /// alight anchor is the first in-fence fix this slow: a train dropping
  /// through 1.0 m/s is within a carriage length of its stop point.
  static const alightSpeedMaxMps = 1.0;

  /// How far from the alight anchor the rider must walk before the exit
  /// counts. 150 m clears a platform-length wander but is crossed within
  /// minutes by anyone actually leaving; on the 18 Jul Kalyan log the
  /// owner's walk crossed it about 6 minutes after the doors opened,
  /// pauses at stairs included.
  static const exitWalkM = 150.0;

  /// Receding from the alight anchor faster than this average pace is a
  /// vehicle, not a walk: a crawling train that picked back up, or a degraded
  /// stream drifting the rider away. It sits above [walkingSpeedMaxMps] to
  /// leave a dead-band, so ordinary walking jitter never reads as a vehicle.
  static const vehicleSpeedMps = 4.0;

  /// A vehicle is disarmed only on SUSTAINED recession: this many continuous
  /// fixes each farther from the anchor than a walk could reach. One is never
  /// enough, so a lone GPS teleport (the 20 Jul 3T Asangaon 157 m jump) does
  /// not permanently end Travel Mode.
  static const vehicleFixesToDisarm = 2;

  /// A gap longer than this between fixes breaks continuity: the missing fixes
  /// could hide either a walk or a train, so the recession streak does not
  /// count across it. On the 20 Jul ride the normal cadence was ~1 s and the
  /// arrival gap was 15 s. Bench-tunable.
  static const vehicleStreakGap = Duration(seconds: 12);

  /// How soon after the first anchor a re-anchor may still happen. The arrival
  /// artifact settles within seconds (the 20 Jul Shahad re-anchor was 37 s in);
  /// a near-stationary dip minutes into the walk, like the Kalyan stairs pause,
  /// is past this window and must not move the anchor forward.
  static const reanchorWindow = Duration(seconds: 90);

  /// Same gate as the other engines: blackout-quality fixes prove nothing.
  static const maxAccuracyM = 150.0;

  bool _armed = false;
  int _qualifyingFixes = 0;
  int _vehicleFixes = 0;
  DateTime? _lastFixAt;
  bool _countingDown = false;
  DateTime? _endAt;

  /// Whether the train provably STOPPED at the destination platform (a
  /// near-stationary fix inside the fence) after the arrival. A rider can
  /// only have alighted from a stopped train; the 13 Jul fast local
  /// crossed the Thakurli fence at 22 m/s and nobody got off it there.
  /// Exit fixes count for nothing until this is seen.
  bool _alightSeen = false;

  /// Where the train stopped: the first near-stationary in-fence fix.
  /// Frozen once set, deliberately. Walking through a crowded station
  /// includes near-stationary dips (the real Kalyan walk read 0.2 to 0.6
  /// m/s at stairs), and re-anchoring on each dip would chase the walker
  /// so the exit distance never accumulates.
  double? _anchorLat;
  double? _anchorLng;

  /// When the anchor was set. The exit walk is only believed if the distance
  /// from the anchor is reachable on foot in the time since: a rider cannot be
  /// 150 m away two seconds after the train stopped.
  DateTime? _anchorAt;

  /// When the FIRST anchor was set (arrival). Re-anchoring is only allowed
  /// within [reanchorWindow] of this, so a mid-walk dip cannot claim it.
  DateTime? _firstAnchorAt;

  /// A GPS gap happened after the anchor was set, so the anchor may be stale:
  /// the missing fixes could hide the train's final crawl to the platform, as
  /// on the 20 Jul Shahad walk where a 15 m/... 135 m jump across a 15 s gap
  /// left the anchor 135 m from where the rider actually alighted. The next
  /// settled (slow, in-fence) fix re-anchors to the real alight point. Only a
  /// gap arms this; a continuous walking dip never re-anchors, so the frozen
  /// anchor still holds through the stairs-pause case it was built for.
  bool _reanchorPending = false;

  /// The anchor may be re-set only ONCE, for the arrival artifact. Later gaps
  /// happen mid-walk (the 20 Jul Shahad walk had a second 41 s gap on the way
  /// to the parking); re-anchoring on those would keep resetting the walker's
  /// accumulated distance so the exit never reaches 150 m.
  bool _reanchored = false;

  /// Whether the auto-off countdown is running. The shell mirrors this into
  /// the notification buttons and the debug screen.
  bool get isCountingDown => _countingDown;

  /// Once the rider is provably still on the train past the destination,
  /// auto-off is off the table for the whole ride: recovery from a missed
  /// stop is manual-end territory.
  bool _disarmed = false;

  /// The arrival at the destination is what arms the exit watch; any later
  /// station event disarms it permanently, because a rider passing another
  /// station is still aboard and the "exit" watch would be watching the
  /// wrong platform.
  ///
  /// ONE EVENT OUTRANKS THAT DISARM: reaching an overshoot pin. A pin is the
  /// app telling the rider "you have passed your stop, get off HERE", so it
  /// is the one later station event that predicts an imminent alighting
  /// rather than ruling one out. It moves the exit watch to that station and
  /// re-arms from scratch.
  ///
  /// It must outrank [_disarmed] rather than sit behind it, and that is the
  /// whole reason the 22 Jul ride never wound down: the train pulling out of
  /// the destination disarms on recession SECONDS after the arrival, long
  /// before the pin is reached, so a re-arm that respected the disarm would
  /// never run on the only journeys that need it.
  List<WindDownAction> onStationEvent(Announcement announcement, DateTime now) {
    if (announcement.kind == AnnouncementKind.overshoot) {
      for (final pin in overshootStations) {
        if (pin.id == announcement.stationId) {
          _rearmAt(pin);
          return const [];
        }
      }
    }
    if (_disarmed) return const [];
    if (announcement.stationId == destination.id &&
        announcement.kind == AnnouncementKind.arrival) {
      _armed = true;
    } else if (_armed) {
      _armed = false;
      _disarmed = true;
      _qualifyingFixes = 0;
    }
    return const [];
  }

  /// Point the exit watch at [station] and clear every trace of the previous
  /// one. The anchor, both streaks and the re-anchor allowance are all
  /// artifacts of an alighting that did not happen, and a stale anchor
  /// hundreds of metres back down the line would read as a phantom vehicle
  /// and disarm again immediately.
  void _rearmAt(Station station) {
    _exitStation = station;
    _armed = true;
    _disarmed = false;
    _alightSeen = false;
    _anchorLat = null;
    _anchorLng = null;
    _anchorAt = null;
    _firstAnchorAt = null;
    _reanchorPending = false;
    _reanchored = false;
    _qualifyingFixes = 0;
    _vehicleFixes = 0;
    _countingDown = false;
    _endAt = null;
  }

  /// One raw GPS fix. After arrival, consecutive walking-speed fixes far
  /// enough from the alight anchor are the platform-exit proof.
  List<WindDownAction> onFix({
    required double lat,
    required double lng,
    required double accuracyM,
    required double speedMps,
    required DateTime now,
  }) {
    if (!_armed && !_countingDown) return const [];
    if (accuracyM > maxAccuracyM) return const [];

    // A gap in the stream breaks the sustained-motion streak: the fix that
    // ends it reports a speed for the whole jump the missing fixes hid, which
    // is not proof of a vehicle. This is what saved the 20 Jul Shahad walk,
    // where a 15 s gap produced a lone 6.2 m/s reading.
    final lastAt = _lastFixAt;
    _lastFixAt = now;
    final continuous =
        lastAt != null && now.difference(lastAt) <= vehicleStreakGap;
    // A gap after we anchored may have hidden the train's final approach, so
    // the anchor may be stale (135 m off, on the 20 Jul Shahad walk). Mark it
    // for re-setting at the next settled fix. Only the FIRST gap, and only
    // inside the re-anchor window; once that passes, trust the anchor and let
    // recession judge normally again.
    if (_alightSeen && !continuous && !_reanchored) _reanchorPending = true;
    if (_reanchorPending &&
        _firstAnchorAt != null &&
        now.difference(_firstAnchorAt!) > reanchorWindow) {
      _reanchorPending = false;
      _reanchored = true;
    }

    final distanceM =
        _distanceM(lat, lng, _exitStation.lat, _exitStation.lng);

    final canReanchor = _reanchorPending && !_reanchored;
    if ((!_alightSeen || canReanchor) &&
        distanceM <= _exitStation.radiusM &&
        speedMps >= 0 &&
        speedMps <= alightSpeedMaxMps) {
      if (_alightSeen) _reanchored = true;
      _alightSeen = true;
      _anchorLat = lat;
      _anchorLng = lng;
      _anchorAt = now;
      _firstAnchorAt ??= now;
      _reanchorPending = false;
      // Both streaks from a stale anchor are void.
      _qualifyingFixes = 0;
      _vehicleFixes = 0;
      return const [];
    }

    final anchorLat = _anchorLat;
    final anchorLng = _anchorLng;
    if (!_alightSeen || anchorLat == null || anchorLng == null) {
      return const [];
    }

    // Everything keys off DISPLACEMENT from the alight anchor over the time
    // since it was set, never the reported per-fix speed. On the 20 Jul ride
    // the reported speed lied both ways: it read 6.2 m/s on a lone gap-jump
    // while the rider walked to the Shahad parking, and 0.0 on a degraded
    // stream while the train carried the rider past Ambivli. Distance over
    // time cannot be faked by a single reading: a walker stays near the
    // alight point, a departing train recedes hundreds of metres fast.
    final walkedM = _distanceM(lat, lng, anchorLat, anchorLng);
    final elapsedS = now.difference(_anchorAt!).inSeconds;
    final walkReachM = walkingSpeedMaxMps * elapsedS;
    final vehicleReachM = vehicleSpeedMps * elapsedS;

    // Receding faster than any walk, sustained: the train left with the
    // rider (or a degraded stream is drifting them away). Disarm auto-off for
    // the ride, live countdown included. Sustained (two continuous fixes) so a
    // lone GPS teleport does not end Travel Mode; silent, the notification
    // still offers End now.
    // Recession is not judged while a re-anchor is pending: the anchor is
    // known stale (a gap hid the real alight point), so its distance would
    // read as a phantom vehicle. It resumes once the anchor re-settles.
    if (!_reanchorPending && continuous && walkedM > vehicleReachM) {
      _vehicleFixes++;
      if (_vehicleFixes >= vehicleFixesToDisarm) {
        _armed = false;
        _disarmed = true;
        _countingDown = false;
        _endAt = null;
        _qualifyingFixes = 0;
        return const [];
      }
    } else {
      _vehicleFixes = 0;
    }
    if (_countingDown) return const [];

    // A walk off the platform: past 150 m from the anchor, but no farther than
    // a walk could have carried the rider in the time since (so a glitch that
    // teleports past 150 m in a second cannot arm it), and at a walking-speed
    // reading. Two continuous fixes confirm it.
    // No continuity requirement here (unlike recession): the walk exit is
    // already guarded by walkedM <= walkReachM, which a gap-jump past 150 m
    // in a second fails on its own. Requiring continuity would also reject a
    // sparse but genuine walk.
    final exitingOnFoot = speedMps >= 0 &&
        speedMps <= walkingSpeedMaxMps &&
        walkedM > exitWalkM &&
        walkedM <= walkReachM;
    if (exitingOnFoot) {
      _qualifyingFixes++;
    } else {
      _qualifyingFixes = 0;
    }

    if (_qualifyingFixes >= exitFixesRequired) {
      _countingDown = true;
      _endAt = now.add(countdown);
      return const [
        WindDownSpeak(
          'Looks like you have left the station. Travel Mode will end in '
          'one minute. Use the notification to end it now, or keep it '
          'running longer.',
        ),
      ];
    }
    return const [];
  }

  /// The [End now] action, from the notification or the debug screen.
  /// Only meaningful while a countdown is live: pressing it any other time
  /// must not tear a ride down.
  List<WindDownAction> endNow(DateTime now) {
    if (!_countingDown) return const [];
    _countingDown = false;
    _endAt = null;
    return const [WindDownEnd()];
  }

  /// The [Extend 10 min] action. Replaces the deadline rather than adding
  /// to it: the rider's press is the moment they asked for more time.
  List<WindDownAction> extend(DateTime now) {
    if (!_countingDown) return const [];
    _endAt = now.add(extension);
    return const [
      WindDownSpeak('Travel Mode will stay on for ten more minutes.'),
    ];
  }

  /// A clock tick from the shell. Fires the end exactly once when the
  /// countdown has run out.
  List<WindDownAction> onTick(DateTime now) {
    if (!_countingDown || _endAt == null || now.isBefore(_endAt!)) {
      return const [];
    }
    _countingDown = false;
    _endAt = null;
    return const [WindDownEnd()];
  }

  /// Great-circle distance in metres (haversine), duplicated from the
  /// sibling engines on purpose: each stays a self-contained pure module.
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
}
