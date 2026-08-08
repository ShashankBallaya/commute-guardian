import '../models/journey.dart';
import '../models/station.dart';

/// What a [RideHealth] wants said. The engine decides, the service speaks.
sealed class RideHealthAction {
  const RideHealthAction();
}

/// Say this out loud, once.
class RideHealthSpeak extends RideHealthAction {
  const RideHealthSpeak(this.text);
  final String text;
}

/// A line for the ride log, and nothing else.
class RideHealthNote extends RideHealthAction {
  const RideHealthNote(this.reason);
  final String reason;
}

/// The handover's edge states (section 4.1) that are notices: GPS_LOST, STALL
/// and WRONG_DIRECTION.
///
/// THE FIRST TWO ARE THE SAME SHAPE, which is why they share an engine: both
/// are "the thing that should be happening has not happened for a while", and
/// both are answered with one sentence and no change to the ride.
/// WRONG_DIRECTION is the odd one, a position claim rather than a clock, but it
/// belongs here because it has the same POWER: a sentence and a log line.
/// Nothing here touches progress, the wake ladder or the wind-down. It cannot
/// make the app announce a station, and it cannot make it fail to.
///
/// WHAT THIS DELIBERATELY DOES NOT DO: DEAD RECKONING.
///
/// The handover's GPS_LOST entry asks for a fallback that keeps the chain
/// moving on average inter-station times. That is refused, and `ride_progress`
/// is the argument. Every rule in that file exists to stop the app claiming a
/// station it cannot evidence: an eliminative claim is held until a second fix
/// corroborates it, a contradicting fix discards it, and the backstop only ever
/// speaks in the PAST tense. All of it was written after 18 Jul 2026, when one
/// 143 m fix in the Thane creek spoke "You have passed Thane" two and a half
/// minutes early and deduped the real arrival into silence.
///
/// Reckoning from a timetable average is that failure as a feature, and on this
/// product the cost is not symmetric: an honest silence leaves the rider where
/// they already were, while a confident wrong station wakes them at the wrong
/// stop or tells them their stop has gone. The app also has no timetable by a
/// locked decision, so the "average" would be invented as well as unevidenced.
///
/// So the rider is TOLD instead, once, with something they can do about it.
/// When fixes come back, `RideProgress`'s own backstop announces every station
/// crossed in the gap, late and in the past tense, which is the honest recovery
/// and already exists.
class RideHealth {
  RideHealth({
    this.origin,
    this.destinationName,
    this.wrongWayStations = const [],
  });

  /// Build the engine from the journey it runs for, like every other engine
  /// here. Wiring the fields by hand at the call site is what made the replay
  /// tool stop reproducing the app.
  factory RideHealth.forJourney(Journey journey) => RideHealth(
    origin: journey.chain.isEmpty ? null : journey.chain.first,
    destinationName: journey.chain.isEmpty ? null : journey.chain.last.name,
    wrongWayStations: journey.wrongWayStations,
  );

  /// Where the rider boards. WRONG_DIRECTION is measured from here, and the
  /// watch does not arm until a fix proves the rider is actually at it.
  final Station? origin;

  /// Spoken name of where the rider is going, for the one sentence that names
  /// it. Null disables the wrong-way notice: a warning that cannot say what it
  /// is warning away from is not worth waking someone for.
  final String? destinationName;

  /// The stations one stop behind [origin]. Matched by proximity, never by
  /// chain order. See [Journey.wrongWayStations].
  final List<Station> wrongWayStations;

  /// No usable fix for this long and the rider is told. Usable means the same
  /// thing it means to RideProgress: inside its accuracy ceiling. A fix the OS
  /// is unsure of does not localise anything, so it is not evidence that the
  /// stream is healthy either.
  ///
  /// Two minutes, not thirty seconds. At the ride's sampling rate that is a
  /// long starvation rather than a wobble, and a warning that fires in every
  /// cutting between Kalwa and Mumbra would train the rider to ignore it.
  static const gpsGap = Duration(minutes: 2);

  /// After the stream recovers, how long before another warning may fire. A
  /// ride through patchy cover must not narrate its own signal strength.
  static const gpsQuiet = Duration(minutes: 15);

  /// A stall is this many times the ride's own median segment so far.
  static const stallFactor = 3;

  /// Below this, no stall is ever reported however the arithmetic comes out.
  /// Mumbai locals sit at signals constantly and a rider who is asleep is the
  /// point of the app; the bar has to be "something is wrong", not "we are a
  /// bit late".
  static const stallFloor = Duration(minutes: 8);

  /// Segments needed before the median means anything.
  static const stallMinSegments = 2;

  DateTime? _lastUsableFix;
  DateTime? _lastCrossing;
  DateTime? _gpsWarnedAt;
  bool _gpsLost = false;
  bool _stallWarned = false;

  /// WRONG_DIRECTION is armed only once a usable fix has put the rider inside
  /// the origin's own fence, and it is disarmed for good the moment the ride
  /// provably moves the right way (or ends).
  ///
  /// ARMING MATTERS AS MUCH AS FIRING. A rider who plans Dadar to Andheri while
  /// still riding INTO Dadar is sitting at a wrong-way pin at the instant the
  /// ride starts, and an unarmed engine would greet them with "you seem to be
  /// heading away from Andheri" before they had boarded anything. This is the
  /// same instinct as RideProgress's first fix, which only localizes: a ride
  /// that starts away from its origin makes no claim about direction until the
  /// rider is somewhere it can measure from.
  ///
  /// The cost of the rule is a MISS, not a false alarm: a rider who starts
  /// Travel Mode from home and walks into the wrong platform never arms the
  /// watch if no fix lands inside the origin fence on the way. On this product
  /// that trade is the right way round, and it is the same asymmetry the whole
  /// engine is built on.
  bool _wrongWayArmed = false;
  bool _wrongWayWatchOver = false;

  /// Stall watching is over for this ride. Set at the destination, and at an
  /// overshoot pin, because after either one there are no more stations to
  /// cross BY DESIGN and every further minute would look like a stall.
  ///
  /// MEASURED, not reasoned: replaying the six real ride logs through this
  /// engine fired "the train seems to be held up" on 22 Jul at 16:02, sixteen
  /// minutes after the Shahad overshoot, while the owner was walking home with
  /// the ride still running. There was no train to be held up.
  bool _stallWatchOver = false;

  /// The rider is changing trains, so the clock does not apply until they are
  /// on the next one.
  ///
  /// ALSO MEASURED. The same replay fired on 18 Jul at 14:58, in the eighteen
  /// minutes between arriving at Thane and reaching Digha Gaon. That gap is the
  /// interchange the app itself announced: get off, walk to platform 9, wait,
  /// board a Trans Harbour train. An interchange is not a stall, and the
  /// journey already knows where every one of them is.
  bool _changing = false;

  /// Every segment this ride has actually taken, in order. THE RIDE'S OWN
  /// TIMES, never a timetable: there is no timetable in this app by a locked
  /// decision, and a rush-hour Kalyan slow and a Sunday fast are different
  /// journeys anyway. A median over what has already happened describes the
  /// train the rider is actually on.
  final List<Duration> _segments = [];

  /// A fix landed. [usable] is passed rather than derived so the caller keeps
  /// ONE definition of usable, the one RideProgress applies.
  ///
  /// [lat] and [lng] are what WRONG_DIRECTION reads. They are optional because
  /// a caller that only wants the health clocks fed has nothing to say about
  /// position, and a fix without coordinates must not arm or fire a claim about
  /// where the rider is.
  List<RideHealthAction> onFix(
    DateTime now, {
    required bool usable,
    double? lat,
    double? lng,
  }) {
    if (!usable) return const [];
    _lastUsableFix = now;
    _lastCrossing ??= now;
    _gpsLost = false;
    if (lat == null || lng == null) return const [];
    return _wrongWayActions(lat, lng);
  }

  /// WRONG_DIRECTION, decided by PROXIMITY ALONE.
  ///
  /// A fix inside a wrong-way pin is direct evidence: the rider is standing at
  /// a station this ride was never going to pass. Nothing is projected, nothing
  /// is eliminated, and no leg is dot-producted, which is deliberate. Every
  /// false announcement this project has shipped came from geometry inferring a
  /// position rather than measuring one: the 12 Jul "you have reached Thane"
  /// 1.19 km early, and the 18 Jul "you have passed Thane" off one 143 m creek
  /// fix. A wrong-direction warning is exactly the kind of sentence a rider
  /// acts on immediately, by getting off a train, so it gets the strictest
  /// evidence in the codebase rather than the cleverest.
  ///
  /// Straight-line distance from the destination was the obvious alternative
  /// and it is wrong on this network: a Thane to Panvel rider leaves Thane
  /// EASTWARD on Trans Harbour while the Central line arrives from the east, so
  /// "moving away from the destination" is the normal shape of a correct ride
  /// for the first several minutes.
  List<RideHealthAction> _wrongWayActions(double lat, double lng) {
    if (_wrongWayWatchOver) return const [];
    final origin = this.origin;
    final destination = destinationName;
    if (origin == null || destination == null) return const [];

    if (!_wrongWayArmed) {
      if (!origin.contains(lat, lng)) return const [];
      _wrongWayArmed = true;
      return const [RideHealthNote('at the origin, wrong-way watch armed')];
    }

    for (final pin in wrongWayStations) {
      if (!pin.contains(lat, lng)) continue;
      // Once is all it gets, whatever the rider does about it.
      _wrongWayWatchOver = true;
      return [
        RideHealthNote('reached ${pin.id}, one stop the wrong way'),
        // It does NOT ask a question. The handover drafted this with
        // notification actions ("Keep Travel Mode running?"), and the app has
        // no notification buttons to answer with (the 30 Jul swipe bench found
        // that every acknowledgement dies with the UI). It also does not need
        // them: nothing is going to be turned off either way, so the honest
        // sentence is the one that says what happened, what to do, and that the
        // ride is still being watched. A rider who rode one stop back the other
        // way is picked up again by the chain when they come through the origin.
        RideHealthSpeak(
          'You seem to be heading away from $destination. If this is the wrong '
          'train, get off at the next station and cross to the other platform. '
          'Travel Mode is still on.',
        ),
      ];
    }
    return const [];
  }

  /// A station was passed or arrived at: the ride is provably moving.
  ///
  /// [changeHere] is an interchange, [endsWatch] the destination or an
  /// overshoot pin. Both come from the journey the service is riding, so this
  /// engine never has to know what a Trans Harbour platform is.
  List<RideHealthAction> onStationPassed(
    DateTime now, {
    String? stationId,
    bool changeHere = false,
    bool endsWatch = false,
  }) {
    // Any station that is not the origin is proof the train is going the right
    // way: the chain only contains stations between origin and destination, so
    // reaching one cannot happen on a wrong-platform train. The origin itself
    // is excluded because RideProgress announces it on the ride's first fix,
    // which would otherwise close the watch before it had ever looked.
    if (!_wrongWayWatchOver && stationId != null && stationId != origin?.id) {
      _wrongWayWatchOver = true;
    }

    if (endsWatch) {
      _wrongWayWatchOver = true;
      _stallWatchOver = true;
      _stallWarned = false;
      _lastCrossing = now;
      return const [RideHealthNote('stall watch over, the ride has arrived')];
    }

    final last = _lastCrossing;
    if (_changing) {
      // The segment that spans a change of train describes a walk and a wait,
      // not a train, so it must not enter the median either.
      _changing = false;
      _lastCrossing = now;
      _stallWarned = false;
      return const [
        RideHealthNote('change of train done, stall clock resumed'),
      ];
    }
    if (changeHere) {
      _changing = true;
      _lastCrossing = now;
      return const [RideHealthNote('change of train, stall clock paused')];
    }
    if (last != null) {
      final segment = now.difference(last);
      // Two announcements for one station (approach then arrival) would
      // otherwise enter a near-zero segment and drag the median down until
      // every gap looked like a stall.
      if (segment >= const Duration(seconds: 30)) _segments.add(segment);
    }
    _lastCrossing = now;
    if (!_stallWarned) return const [];
    _stallWarned = false;
    return const [RideHealthNote('stall cleared, the train is moving')];
  }

  /// One tick.
  List<RideHealthAction> onTick(DateTime now) {
    return [..._gpsActions(now), ..._stallActions(now)];
  }

  List<RideHealthAction> _gpsActions(DateTime now) {
    final last = _lastUsableFix;
    if (last == null) return const [];
    if (now.difference(last) < gpsGap) return const [];
    if (_gpsLost) return const [];
    _gpsLost = true;

    final warnedAt = _gpsWarnedAt;
    if (warnedAt != null && now.difference(warnedAt) < gpsQuiet) {
      return const [RideHealthNote('GPS gap again, inside the quiet window')];
    }
    _gpsWarnedAt = now;
    return const [
      RideHealthNote('no usable fix for two minutes'),
      // Actionable, and true. It does NOT promise to keep counting stations,
      // because without fixes it cannot: what it promises is that the ride is
      // still running, which is the part a rider would otherwise doubt.
      RideHealthSpeak(
        'The signal is weak here. Travel Mode is still on. If you can, move '
        'near a door or a window.',
      ),
    ];
  }

  List<RideHealthAction> _stallActions(DateTime now) {
    if (_stallWarned || _stallWatchOver || _changing) return const [];
    final last = _lastCrossing;
    if (last == null) return const [];
    if (_segments.length < stallMinSegments) return const [];
    // A stall cannot be diagnosed while the fixes are gone: the train may have
    // passed three stations unheard. The rider has already been told about the
    // signal, and two warnings about one silence is one too many.
    if (_gpsLost) return const [];

    final threshold = _median() * stallFactor;
    final waited = now.difference(last);
    if (waited < threshold || waited < stallFloor) return const [];

    _stallWarned = true;
    return [
      RideHealthNote(
        '${waited.inMinutes} min since the last station, '
        'median segment ${_median().inMinutes} min',
      ),
      // GENTLE, and it says nothing about why. The app does not know whether
      // this is a signal failure at Diva or a chain snatching at Mumbra, and a
      // guess would be the thing a rider quotes back at it.
      const RideHealthSpeak(
        'The train seems to be held up. Travel Mode is still on and I am still '
        'watching for your stop.',
      ),
    ];
  }

  Duration _median() {
    final sorted = [..._segments]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return Duration(
      milliseconds:
          ((sorted[middle - 1].inMilliseconds + sorted[middle].inMilliseconds) /
                  2)
              .round(),
    );
  }
}
