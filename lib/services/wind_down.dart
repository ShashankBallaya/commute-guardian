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
  WindDown({required this.destination});

  final Station destination;

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

  /// Above this the rider is provably in a vehicle again, so the "exit"
  /// reading is wrong (a crawling train that picked back up, or a rickshaw
  /// straight from the gate). One such fix stands auto-off down permanently
  /// and cancels any live countdown: ending Travel Mode from inside a
  /// moving vehicle is exactly the mistake the overshoot net exists to
  /// survive. The old fence-band rule guarded the same 13 Jul crawl case;
  /// the speed cancel replaces it without needing the fence.
  static const vehicleSpeedMps = 4.0;

  /// Speeds between [walkingSpeedMaxMps] and [vehicleSpeedMps] are the
  /// ambiguous band: too fast to be a walk, too slow to prove a vehicle.
  /// A single such fix only breaks the walking streak, because a real
  /// walker throws jog-speed noise and must not lose auto-off for it. Two
  /// in a row is a different claim: GPS noise rarely repeats, while a train
  /// accelerating off the platform sits in this band for several fixes on
  /// its way up. Without this, a sparse fix stream that happened to sample
  /// a departing train only below 2.5 m/s could still arm the countdown,
  /// which is the "can never end under a sleeping rider" promise broken.
  static const ambiguousFixesToDisarm = 2;

  /// Same gate as the other engines: blackout-quality fixes prove nothing.
  static const maxAccuracyM = 150.0;

  bool _armed = false;
  int _qualifyingFixes = 0;
  int _ambiguousFixes = 0;
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
  List<WindDownAction> onStationEvent(Announcement announcement, DateTime now) {
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

    // Vehicle speed after the alight kills auto-off for the ride, live
    // countdown included. Cancelling is silent: if this was a crawling
    // train picking back up the rider is asleep, and if it was a rickshaw
    // the notification still offers End now.
    if (_alightSeen && speedMps > walkingSpeedMaxMps) {
      _ambiguousFixes++;
      final provenVehicle = speedMps > vehicleSpeedMps ||
          _ambiguousFixes >= ambiguousFixesToDisarm;
      if (provenVehicle) {
        _armed = false;
        _disarmed = true;
        _countingDown = false;
        _endAt = null;
        _qualifyingFixes = 0;
        return const [];
      }
    } else {
      _ambiguousFixes = 0;
    }
    if (_countingDown) return const [];

    final distanceM =
        _distanceM(lat, lng, destination.lat, destination.lng);

    if (!_alightSeen &&
        distanceM <= destination.radiusM &&
        speedMps <= alightSpeedMaxMps) {
      _alightSeen = true;
      _anchorLat = lat;
      _anchorLng = lng;
      return const [];
    }

    final anchorLat = _anchorLat;
    final anchorLng = _anchorLng;
    if (!_alightSeen || anchorLat == null || anchorLng == null) {
      return const [];
    }

    final walkedM = _distanceM(lat, lng, anchorLat, anchorLng);
    final exitingOnFoot =
        speedMps <= walkingSpeedMaxMps && walkedM > exitWalkM;
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
