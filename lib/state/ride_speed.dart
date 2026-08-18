import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How fast the train is going, for the speed screen.
///
/// SEPARATE FROM [LiveRide] ON PURPOSE, and for the same reason the interrupted
/// ride is: this changes on EVERY fix, about once a second. Folding it into the
/// provider that Screen 4, the ride notification and the alert routing all watch
/// would rebuild the ride screen once a second for a number it does not show.
/// Screen 4 is held in a pocket for 45 minutes; it does not get to rebuild at
/// 1 Hz so that another screen can be interesting.
class RideSpeed {
  const RideSpeed({this.kmh, this.at, this.maxKmh});

  /// The last reading, or null when the platform would not say. NEVER -1: the
  /// sentinel dies in `parseServiceData`, at the isolate boundary.
  final double? kmh;

  /// When that reading arrived, for the staleness rule below.
  final DateTime? at;

  /// The fastest reading this ride. Null until there has been one.
  ///
  /// KEPT BECAUSE IT IS THE ONLY PART A RIDER REMEMBERS. A live number is
  /// interesting for a second; "we hit 107" is what gets told to somebody else.
  final double? maxKmh;

  /// How old a reading may be and still be shown.
  ///
  /// TWENTY SECONDS, and the number comes from this project's own logs rather
  /// than from taste: the largest gaps in the 18 Aug desk log were about 15 s,
  /// stationary, with iOS coalescing hard. Twenty clears that with room.
  ///
  /// It matters because a stale reading is the one dishonest thing this screen
  /// could do. At line speed a 20 s old number is 600 m out of date, and a
  /// screen that says 80 while the train stands at a signal is worse than a
  /// screen that admits it does not know.
  static const staleAfter = Duration(seconds: 20);

  /// The reading to SHOW, given the time now. Null means "no reading", which is
  /// a state this screen draws rather than a value it hides.
  double? shownKmh(DateTime now) {
    final reading = kmh;
    final stamp = at;
    if (reading == null || stamp == null) return null;
    return now.difference(stamp) > staleAfter ? null : reading;
  }
}

/// Fed by the ServiceFix events the ride already sends up.
class RideSpeedNotifier extends Notifier<RideSpeed> {
  @override
  RideSpeed build() => const RideSpeed();

  /// Below this, a reading is jitter rather than travel, for the MAXIMUM only.
  ///
  /// MEASURED, NOT GUESSED: the first build of this screen sat on a desk that
  /// had not moved all evening and reported "Fastest this ride 2 km/h". Android
  /// returns a real speed rather than a -1 sentinel, and a stationary GPS
  /// wanders. The live number still shows the truth, whatever it is; this only
  /// stops noise from becoming the one figure a rider repeats to somebody else.
  ///
  /// Five is brisk walking pace. No train this app will ever be on peaks below
  /// it, so nothing real can be lost here.
  static const _jitterFloorKmh = 5.0;

  /// A fix arrived. [kmh] is null when the platform would not say.
  ///
  /// THE MAXIMUM ONLY EVER RISES, and never from a null: a stretch with no
  /// readings must not reset what the ride has already done.
  void applyFix(double? kmh, DateTime at) {
    final max = state.maxKmh;
    final counts = kmh != null && kmh >= _jitterFloorKmh;
    state = RideSpeed(
      kmh: kmh,
      at: kmh == null ? state.at : at,
      maxKmh: !counts ? max : (max == null || kmh > max ? kmh : max),
    );
  }

  /// A new ride. The maximum belongs to ONE journey, so this is not optional:
  /// carrying yesterday's 107 into today's ride would be the same class of bug
  /// as a new ride inheriting the last one's progress index.
  void reset() => state = const RideSpeed();
}

final rideSpeedProvider = NotifierProvider<RideSpeedNotifier, RideSpeed>(
  RideSpeedNotifier.new,
);
