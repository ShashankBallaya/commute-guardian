import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/journey.dart';
import '../models/station.dart';
import 'ride_progress.dart';
import 'spoken_copy.dart';

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

/// A diagnostic for the ride log, never spoken.
///
/// Exists because SILENCE HAS NO CAUSE IN A LOG: a wind-down that armed and
/// was disarmed looks exactly like one that never armed at all, and after the
/// 22 Jul ride that ambiguity cost a session of guessing (and one confidently
/// wrong root cause). Same fix as bb19b39 gave the wake ack: make the engine
/// say WHY, in the file, at the moment it decides.
class WindDownNote extends WindDownAction {
  const WindDownNote(this.reason);
  final String reason;
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
  WindDown({
    required this.destination,
    this.overshootStations = const [],
    this.language = AppLanguage.english,
  }) : _exitStation = destination;

  /// Build the engine from the journey it runs for. Everything this needs is
  /// already on [Journey], and every caller (the service and the replay tool)
  /// wants exactly this, so wiring the fields by hand at each call site only
  /// created the chance for one of them to forget a field. Exactly that
  /// happened once: the replay tool stopped passing the overshoot pins and
  /// went silently blind to every overshoot for two commits.
  factory WindDown.forJourney(
    Journey journey, {
    AppLanguage language = AppLanguage.english,
  }) => WindDown(
    destination: journey.chain.firstWhere(
      (s) => s.id == journey.destinationStationId,
    ),
    overshootStations: journey.overshootStations,
    language: language,
  );

  final Station destination;

  /// What the two wind-down lines are spoken in.
  final AppLanguage language;

  late final SpokenCopy _copy = SpokenCopy(language);

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

  /// The station the rider is going to get off at, which after an overshoot is
  /// NOT the one they picked.
  ///
  /// PUBLISHED BECAUSE THE FACT EXISTED HERE AND TRAVELLED NOWHERE. This engine
  /// has moved its exit watch to an overshoot pin since the 22 Jul ride, so it
  /// has always known where the rider actually alights; Screen 5 read the
  /// destination instead and would have said "You've arrived at Shahad" to
  /// someone standing at Ambivli. The service isolate sends and saves this the
  /// same way it does progress.
  String get alightStationId => _exitStation.id;

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

  /// Recession is a RATE, and a rate measured over a few seconds is mostly
  /// position noise. The 22 Jul iPhone leg anchored at Shahad and disarmed
  /// 8 seconds later on "61 m in 7 s", which is the fix stream settling after
  /// the doors opened, not a train: at a 7 s baseline the bar is only 28 m,
  /// well inside the jitter of a 20 m-accuracy fix. Because the disarm is
  /// permanent, that cost the rider auto-off for the whole journey.
  ///
  /// Waiting costs nothing, and that is what makes this safe: the walk exit
  /// needs walkedM > 150 AND walkedM <= 2.5 * elapsed, so it cannot fire
  /// before ~61 s no matter what the rider does. A vehicle verdict at 30 s
  /// still beats it by half a minute.
  static const vehicleMinElapsed = Duration(seconds: 30);

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

  /// How far back the anchor looks to prove the train really stopped.
  ///
  /// The anchor used to be set on ONE reported `speed <= alightSpeedMaxMps`
  /// reading, which contradicted this file's own rule twelve lines below: never
  /// trust the reported per-fix speed, key off displacement. The 9 Aug 2026
  /// iPhone ride is what the contradiction cost. iOS emits an isolated 0.0 m/s
  /// reading while the train is still braking, sometimes with the previous
  /// coordinate repeated verbatim:
  ///
  ///     20:08:49  19.16668, 73.23845  speed 5.5 m/s
  ///     20:08:50  19.16668, 73.23845  speed 0.0 m/s   <- anchored here
  ///     20:08:51  19.16667, 73.23851  speed 4.6 m/s
  ///     ...deceleration continues...
  ///     20:09:02  19.16658, 73.23879  speed 0.0 m/s   <- the train stops here
  ///
  /// So the anchor landed twelve seconds up the line from the true stop, and
  /// every displacement measured from it charged the train's remaining braking
  /// distance to the rider's walk. At Ambernath the same evening the anchor
  /// went in 35 s early, on the first of SEVEN fixes carrying an identical
  /// coordinate with the accuracy decaying 14 m to 21 m underneath it, which is
  /// a held fix and not a stationary train.
  ///
  /// Now the anchor asks the same question the recession judge asks: how far
  /// has this thing actually moved. Five seconds is long enough that a braking
  /// train cannot hide inside it and short enough that the rider has not left
  /// the platform yet.
  static const anchorLookback = Duration(seconds: 5);

  /// A vehicle verdict needs this much ground covered, whatever the arithmetic
  /// says about pace. MEASURED, and it is the one constant here set from a true
  /// positive rather than from reasoning.
  ///
  /// Replaying every real leg gives one correct disarm and three wrong ones:
  ///
  ///   22 Jul thane to kalyan   1058 m over 257 s   4.1 m/s   CORRECT
  ///   9 Aug iPhone ambernath    190 m over  32 s   5.9 m/s   wrong
  ///   9 Aug iPhone badlapur     153 m over  31 s   4.9 m/s   wrong
  ///   9 Aug iPhone kalyan       220 m over  30 s   7.3 m/s   wrong
  ///
  /// PACE DOES NOT SEPARATE THEM. The true positive is the slowest of the four,
  /// because the rider sat in a stationary train at Kalyan for most of those
  /// 257 s before it pulled out with him aboard. Distance separates them by
  /// five times over, and it is also the honest question: a train that has not
  /// carried the rider 400 m has not carried them anywhere yet.
  ///
  /// This costs the true positive NOTHING. 1058 m was already on the clock at
  /// the instant it fired, so the verdict lands on the same fix as before.
  static const vehicleMinRecessionM = 400.0;

  /// Whether this engine has already called the ride over. Terminal: a
  /// WindDownEnd is emitted at most once per ride, and nothing this engine is
  /// told afterwards produces anything.
  ///
  /// Without it the exit streak simply starts again. The rider is still
  /// walking, still past the 150 m mark, and still at walking pace, so the
  /// next two fixes re-qualify and a fresh countdown announces itself about a
  /// minute later, forever. Replaying the 22 Jul return leg shows it plainly:
  /// after the 15:53 auto-off, the 3T goes on to announce and end another
  /// FIFTEEN times, the last at 16:10.
  ///
  /// In production it has been invisible because the shell stops the service
  /// on the first WindDownEnd, so the engine dies before it can repeat. That
  /// makes this a latent bug rather than a harmless quirk: it is masked by the
  /// teardown, not prevented by anything, and it would surface the moment an
  /// end is slow, fails, or gets a confirmation step in front of it.
  bool _ended = false;

  bool _armed = false;
  int _qualifyingFixes = 0;
  int _vehicleFixes = 0;
  DateTime? _lastFixAt;

  /// Recent fixes, oldest first, trimmed to [anchorLookback]. Only the anchor
  /// gate reads this, and it holds a handful of entries at a 1 Hz stream.
  final List<_Anchor> _recent = [];
  bool _countingDown = false;
  DateTime? _endAt;

  /// The window the live deadline was set from: [countdown] normally,
  /// [extension] after an Extend. Screen 5 draws its ring as a fraction of
  /// this, so a countdown and an extended countdown cannot look identical.
  Duration _window = countdown;

  /// Where and when the train stopped: the first near-stationary in-fence fix.
  ///
  /// Frozen once set, deliberately. Walking through a crowded station includes
  /// near-stationary dips (the real Kalyan walk read 0.2 to 0.6 m/s at stairs),
  /// and re-anchoring on each dip would chase the walker so the exit distance
  /// never accumulates.
  _Anchor? _anchor;

  /// Whether the train provably STOPPED at the exit station platform (a
  /// near-stationary fix inside the fence) after the arrival. A rider can
  /// only have alighted from a stopped train; the 13 Jul fast local
  /// crossed the Thakurli fence at 22 m/s and nobody got off it there.
  /// Exit fixes count for nothing until this is seen.
  ///
  /// Derived from the anchor rather than tracked beside it: the two were always
  /// set and cleared together, so a separate flag was one more thing a future
  /// reset could forget.
  bool get _alightSeen => _anchor != null;

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

  /// When Travel Mode ends by itself, or null when nothing is counting.
  ///
  /// Exposed for Screen 5, which shows the rider the time they have left. It
  /// has to travel from this isolate rather than be reconstructed on the other
  /// side: a UI born mid-countdown (the swipe case) would otherwise draw a
  /// fresh sixty seconds over five real ones, and an Extend would not show at
  /// all.
  DateTime? get endsAt => _countingDown ? _endAt : null;

  /// The window [endsAt] was set from. See [_window].
  Duration get window => _window;

  /// Once the rider is provably still on the train past the destination,
  /// auto-off is off the table until the app tells them where to get off:
  /// there is no exit to watch for while they are still aboard.
  ///
  /// This used to be permanent for the ride, and that was the bug the 22 Jul
  /// ride exposed. Reaching an overshoot pin lifts it (see [onStationEvent]),
  /// because a pin names a platform the rider is about to stand on. Nothing
  /// else does.
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
    if (_ended) return const [];
    if (announcement.kind == AnnouncementKind.overshoot) {
      for (final pin in overshootStations) {
        if (pin.id == announcement.stationId) {
          _rearmAt(pin);
          return [WindDownNote('re-armed at overshoot pin ${pin.id}')];
        }
      }
    }
    if (_disarmed) return const [];
    if (announcement.stationId == destination.id &&
        announcement.kind == AnnouncementKind.arrival) {
      _armed = true;
      return const [WindDownNote('armed on destination arrival')];
    } else if (_armed) {
      _armed = false;
      _disarmed = true;
      _qualifyingFixes = 0;
      return [
        WindDownNote(
          'disarmed: ${announcement.stationId} '
          '${announcement.kind.name} after arrival, rider still aboard',
        ),
      ];
    }
    return const [];
  }

  /// Point the exit watch at [station] and clear every trace of the previous
  /// one. The anchor, both streaks and the re-anchor allowance are all
  /// artifacts of an alighting that did not happen, and a stale anchor
  /// hundreds of metres back down the line would read as a phantom vehicle
  /// and disarm again immediately.
  /// Has the rider actually come to rest over the last [anchorLookback]?
  ///
  /// Displacement over the preceding few seconds, never the reported speed. A
  /// braking train covers twenty metres in five seconds and a stopped one
  /// covers almost none, so this is the question the anchor should always have
  /// asked.
  ///
  /// NO EVIDENCE MEANS YES, deliberately. A sparse stream (the 3T routinely
  /// goes 7 to 30 s between fixes after arrival, and several correct anchors on
  /// real logs sit right after a gap) carries no lookback sample, and refusing
  /// to anchor there would break the platform exit on the quieter platform to
  /// fix a fault that only a dense stream can produce. This tightens the 1 Hz
  /// case, which is the only one that ever misfired.
  bool _settledOverLookback(double lat, double lng, DateTime now) {
    _recent.removeWhere((f) => now.difference(f.at) > anchorLookback);
    if (_recent.isEmpty) return true;
    final oldest = _recent.first;
    final elapsed = now.difference(oldest.at);
    // Too recent to say anything: a walker and a train look identical over one
    // second at these accuracies.
    if (elapsed < const Duration(seconds: 3)) return true;
    final moved = _distanceM(lat, lng, oldest.lat, oldest.lng);
    return moved <= walkingSpeedMaxMps * elapsed.inSeconds;
  }

  void _rearmAt(Station station) {
    _exitStation = station;
    _armed = true;
    _disarmed = false;
    _anchor = null;
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
    if (_ended) return const [];
    if (!_armed && !_countingDown) return const [];
    if (accuracyM > maxAccuracyM) return const [];

    // A gap in the stream breaks the sustained-motion streak: the fix that
    // ends it reports a speed for the whole jump the missing fixes hid, which
    // is not proof of a vehicle. This is what saved the 20 Jul Shahad walk,
    // where a 15 s gap produced a lone 6.2 m/s reading.
    final lastAt = _lastFixAt;
    _lastFixAt = now;
    // Recorded before any decision below, and read by the anchor gate through
    // _settledOverLookback, which trims to the window and ignores this entry by
    // comparing against the OLDEST one.
    _recent.add(_Anchor(lat: lat, lng: lng, at: now));
    _recent.removeWhere((f) => now.difference(f.at) > anchorLookback);
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

    final distanceM = _distanceM(lat, lng, _exitStation.lat, _exitStation.lng);

    final canReanchor = _reanchorPending && !_reanchored;
    if ((!_alightSeen || canReanchor) &&
        distanceM <= _exitStation.radiusM &&
        speedMps >= 0 &&
        speedMps <= alightSpeedMaxMps &&
        _settledOverLookback(lat, lng, now)) {
      // Checked before the anchor moves, because _alightSeen reads the anchor.
      if (_alightSeen) _reanchored = true;
      _anchor = _Anchor(lat: lat, lng: lng, at: now);
      _firstAnchorAt ??= now;
      _reanchorPending = false;
      // Both streaks from a stale anchor are void.
      _qualifyingFixes = 0;
      _vehicleFixes = 0;
      return [
        WindDownNote(
          '${_reanchored ? 're-anchored' : 'alight anchor set'} '
          '${distanceM.round()} m from ${_exitStation.id}',
        ),
      ];
    }

    final anchor = _anchor;
    if (anchor == null) return const [];

    // Everything keys off DISPLACEMENT from the alight anchor over the time
    // since it was set, never the reported per-fix speed. On the 20 Jul ride
    // the reported speed lied both ways: it read 6.2 m/s on a lone gap-jump
    // while the rider walked to the Shahad parking, and 0.0 on a degraded
    // stream while the train carried the rider past Ambivli. Distance over
    // time cannot be faked by a single reading: a walker stays near the
    // alight point, a departing train recedes hundreds of metres fast.
    final walkedM = _distanceM(lat, lng, anchor.lat, anchor.lng);
    final elapsedS = now.difference(anchor.at).inSeconds;
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
    if (!_reanchorPending &&
        continuous &&
        elapsedS >= vehicleMinElapsed.inSeconds &&
        walkedM >= vehicleMinRecessionM &&
        walkedM > vehicleReachM) {
      _vehicleFixes++;
      if (_vehicleFixes >= vehicleFixesToDisarm) {
        final wasCountingDown = _countingDown;
        _armed = false;
        _disarmed = true;
        _countingDown = false;
        _endAt = null;
        _qualifyingFixes = 0;
        return [
          WindDownNote(
            'disarmed: receded ${walkedM.round()} m from the '
            '${_exitStation.id} anchor in ${elapsedS}s, over the '
            '${vehicleReachM.round()} m a walk allows'
            '${wasCountingDown ? ', countdown cancelled' : ''}',
          ),
        ];
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
    final exitingOnFoot =
        speedMps >= 0 &&
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
      _window = countdown;
      return [WindDownSpeak(_copy.windDownStarted())];
    }
    return const [];
  }

  /// The [End now] action, from the notification or the debug screen.
  /// Only meaningful while a countdown is live: pressing it any other time
  /// must not tear a ride down.
  List<WindDownAction> endNow(DateTime now) {
    if (_ended || !_countingDown) return const [];
    return _finish();
  }

  /// Calls the ride over, once. Both endings share this so they cannot drift
  /// on what a finished ride leaves behind.
  List<WindDownAction> _finish() {
    _countingDown = false;
    _endAt = null;
    _ended = true;
    return const [WindDownEnd()];
  }

  /// The [Extend 10 min] action. Replaces the deadline rather than adding
  /// to it: the rider's press is the moment they asked for more time.
  List<WindDownAction> extend(DateTime now) {
    if (_ended || !_countingDown) return const [];
    _endAt = now.add(extension);
    _window = extension;
    return [WindDownSpeak(_copy.windDownExtended())];
  }

  /// A clock tick from the shell. Fires the end exactly once when the
  /// countdown has run out.
  List<WindDownAction> onTick(DateTime now) {
    if (_ended || !_countingDown || _endAt == null || now.isBefore(_endAt!)) {
      return const [];
    }
    return _finish();
  }

  /// Great-circle distance in metres (haversine), duplicated from the
  /// sibling engines on purpose: each stays a self-contained pure module.
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
}

/// The alight anchor: where the train stopped, and when.
///
/// One value rather than three parallel nullables, because the position and
/// the instant are meaningless apart. Every judgement this engine makes is
/// distance from here over time since then, so a position without its
/// timestamp cannot say whether a walk was plausible, and either one missing
/// means there is no anchor at all.
class _Anchor {
  const _Anchor({required this.lat, required this.lng, required this.at});

  final double lat;
  final double lng;
  final DateTime at;
}
