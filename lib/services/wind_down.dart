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
/// in, outputs are data. It waits for proof the rider actually alighted,
/// walking-speed fixes OUTSIDE the destination fence after the arrival, and
/// only then starts the 60 second auto-off countdown. A rider carried past
/// their stop asleep leaves the fence at TRAIN speed, so the countdown
/// never starts and the overshoot net stays alive.
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

  /// Same gate as the other engines: blackout-quality fixes prove nothing.
  static const maxAccuracyM = 150.0;

  bool _armed = false;
  int _qualifyingFixes = 0;
  bool _countingDown = false;
  DateTime? _endAt;

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

  /// One raw GPS fix. After arrival, consecutive walking-speed fixes
  /// outside the destination fence are the platform-exit proof.
  List<WindDownAction> onFix({
    required double lat,
    required double lng,
    required double accuracyM,
    required double speedMps,
    required DateTime now,
  }) {
    if (!_armed || _countingDown) return const [];
    if (accuracyM > maxAccuracyM) return const [];

    final outsideFence =
        _distanceM(lat, lng, destination.lat, destination.lng) >
            destination.radiusM;
    if (outsideFence && speedMps <= walkingSpeedMaxMps) {
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
