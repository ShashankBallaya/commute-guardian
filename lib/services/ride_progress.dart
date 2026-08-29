import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/journey.dart';
import '../models/station.dart';
import 'announcement_templates.dart';

/// The kind of announcement an [Announcement] represents.
enum AnnouncementKind { approach, arrival, passed, overshoot }

/// A single announcement the ride wants spoken, decided by [RideProgress].
class Announcement {
  const Announcement({
    required this.stationId,
    required this.kind,
    required this.text,
  });

  final String stationId;
  final AnnouncementKind kind;
  final String text;
}

/// Pure, platform-free decision engine for station announcements.
///
/// Fed one GPS fix at a time via [onFix], it tracks progress along an ordered
/// [chain] and returns the announcements that fix newly triggers. It exists as
/// a software backstop to the native geofence engine: because it reasons about
/// the chain rather than waiting for a fix to land inside a fence, it still
/// announces a station the native engine skipped when a sparse-fix gap jumped
/// the fence or an accuracy blackout hid it.
class RideProgress {
  RideProgress({
    required this.chain,
    required this.destinationStationId,
    this.overshootStations = const [],
    this.approachRadiusM = const {},
    this.arrivalAnnouncements = const {},
    this.walkInterchangeStationIds = const {},
    this.walkCrossings = const {},
    this.maxAccuracyM = 150,
    this.language = AppLanguage.english,
  });

  /// Build the engine from the journey it runs for. See [WindDown.forJourney]
  /// for why every caller should use these rather than wire the fields up by
  /// hand: this is the engine the replay tool went blind on.
  factory RideProgress.forJourney(
    Journey journey, {
    AppLanguage language = AppLanguage.english,
  }) => RideProgress(
    chain: journey.chain,
    destinationStationId: journey.destinationStationId,
    overshootStations: journey.overshootStations,
    approachRadiusM: journey.approachRadiusM,
    arrivalAnnouncements: journey.arrivalAnnouncementsIn(language),
    walkInterchangeStationIds: {
      for (final interchange in journey.interchanges)
        if (interchange.walkToStationName != null) interchange.stationId,
    },
    walkCrossings: {
      for (final interchange in journey.interchanges)
        if (interchange.walkCrossing != null)
          interchange.stationId: interchange.walkCrossing!,
    },
    language: language,
  );

  final List<Station> chain;
  final String destinationStationId;

  /// The safety-net stations one stop past the destination, OUTSIDE [chain].
  ///
  /// Past a terminus there is more than one, because a through service can run
  /// onto either branch and the plan cannot know which. They are matched by
  /// proximity alone and never take part in chain projection: they diverge
  /// geographically, so treating one as a chain slot would project the train
  /// past stations no fix has evidenced. That is the shape of the 18 Jul false
  /// "You have passed Thane".
  final List<Station> overshootStations;
  final Map<String, int> approachRadiusM;
  final Map<String, String> arrivalAnnouncements;

  /// The interchanges this route reaches ON FOOT, keyed by the station the
  /// rider alights at. Both halves of such a pair sit on [chain], so the slot
  /// after one of these is its OTHER HALF across the foot overbridge, not a
  /// station further along the line. [WakeEscalation] carries the same set for
  /// the same reason.
  ///
  /// THE CHAIN CANNOT BE PROJECTED THROUGH A WALK PAIR, and the 28 Aug 2026
  /// ride is why. Dadar Central sits 205 m SOUTH of Dadar Western (the Central
  /// platforms end further south, which the owner confirmed from the ground),
  /// so on a Kalyan to Churchgate plan the leg into Dadar Western is the walk,
  /// pointing NORTH, while the train arrives heading south. Every fix on the
  /// approach from Matunga was therefore "beyond" Dadar Western along its own
  /// inbound leg, and 450 m fences 205 m apart meant the train was inside the
  /// far fence before it reached the near platform. Both phones spoke "You
  /// have passed Dadar Central" and "You have passed Dadar Western" at
  /// 19:56:17, 12 and 23 seconds BEFORE entering either fence, to a rider who
  /// still had to get off at Dadar. The real arrival was deduped into silence,
  /// which is the same damage the 18 Jul Thane false positive did.
  ///
  /// So the pair answers as ONE PLACE, its near half, until that half is
  /// reached: see [_behindItsWalkPair]. The chain passes through the pair, in
  /// order, and never through one half of it.
  final Set<String> walkInterchangeStationIds;

  /// The rails the rider crosses to reach the far half of a walk pair, keyed
  /// by the station they alight at, as an ordered run of points along the
  /// track. See [Interchange.walkCrossing].
  ///
  /// WHY A LINE AND NOT A FENCE. The far half's own fence cannot be used: on
  /// the 28 Aug 2026 ride the phone never came within 88 m of the Dadar
  /// Western node, because the rider waited at the south end of a 250 m
  /// platform, so any circle small enough to mean "here" would have missed
  /// him. Which SIDE of the rails he stood on separated the two halves with
  /// nothing in between: 139 fixes on the Central platform never passed +1 m
  /// and 238 fixes at Dadar Western never came below +58 m.
  ///
  /// A pair with no line keeps the older behaviour, which is to announce the
  /// far half as soon as the near one is reached.
  final Map<String, List<(double, double)>> walkCrossings;

  /// How far past the rails, toward the far half, the rider must be before the
  /// far half is theirs. Sits in the middle of the empty band the ride
  /// measured (+1 to +58), so it is about 29 m clear of both clusters, against
  /// fixes accurate to 14 m.
  static const walkCrossingBoundaryM = 30.0;

  /// The accuracy this one decision needs. [maxAccuracyM] admits 150 m fixes,
  /// which say nothing at all against a 30 m boundary.
  static const walkCrossingMaxAccuracyM = 50.0;

  /// How near the pair the rider must be for the crossing line to still
  /// describe the rails.
  ///
  /// A STRAIGHT LINE STOPS BEING THE TRACK once you leave the station. Run up
  /// the corridor, the Dadar line puts the approaching train 148 m on the
  /// WRONG side near Sion, because the real alignment curves and the line does
  /// not. The question is only ever asked within sight of the pair.
  static const walkCrossingRangeM = 400.0;

  static const _metresPerDegree = 111320.0;

  final double maxAccuracyM;

  /// What the announcements are spoken in. Decides both the template and the
  /// station name inside it, which must be the same language: see
  /// [Station.nameIn].
  final AppLanguage language;

  final Set<String> _announcedArrivals = {};
  final Set<String> _announcedApproaches = {};

  /// Highest chain index the train has provably reached, or -1 until the first
  /// usable fix localizes it.
  int _reachedIndex = -1;

  /// How far along [chain] the rider is provably confirmed, or -1 before the
  /// first station is claimed.
  ///
  /// PUBLISHED SO THERE IS ONLY ONE PROJECTOR. Screen 4 draws the whole ride
  /// from this: stations passed, "you are here", and what is still ahead. The
  /// UI could re-derive it from the raw fix stream, which it already receives,
  /// but that would be a SECOND projector against the same chain and it would
  /// drift. This project has been bitten by that shape before, which is why the
  /// engines gained forJourney factories after the replay tool silently stopped
  /// matching the service.
  int get reachedIndex => _reachedIndex;

  /// Whether the rider is standing IN the station at [reachedIndex], rather
  /// than somewhere past it on the way to the next one.
  ///
  /// THE ENGINE ALWAYS KNEW THIS AND NEVER SAID IT, which is what the 9 Aug
  /// ride found on the screen. `reachedIndex` alone conflates two states a
  /// rider can tell apart by looking out of the window: at Vithalwadi, and
  /// past Vithalwadi. Screen 4 drew the second one for both, so a train
  /// standing at a platform said "Vithalwadi" as history and "You are here"
  /// underneath it. The owner's words: it should still show you are in
  /// Vithalwadi while the train is stationary there.
  ///
  /// Deliberately a boolean about the REACHED station rather than an index of
  /// its own. A fix inside some other station's fence, which can only happen
  /// by going backwards along the chain, must not be able to walk the screen's
  /// marker back: the chain only ratchets forward and this must agree with it.
  bool get atReachedStation => _atReachedStation;
  bool _atReachedStation = false;

  /// A passed-station claim from the previous usable fix that rested on
  /// elimination alone, held until the next usable fix agrees, or -1 when
  /// nothing is pending. See the corroboration rule in [onFix].
  int _pendingEliminativeIndex = -1;

  /// Announcements newly triggered by this fix, in chain order. Each station's
  /// approach/arrival/overshoot fires at most once for the whole ride.
  List<Announcement> onFix({
    required double lat,
    required double lng,
    required double accuracyM,
  }) {
    // A fix the OS is unsure of (accuracy blackout) must not localize or
    // advance progress: acting on it would announce the wrong station or skip
    // one. Wait for a confident fix.
    if (accuracyM > maxAccuracyM) {
      return const [];
    }

    // The overshoot net comes first and answers alone. Reaching a pin means
    // the alight was missed, so the only useful thing to say is "get off
    // here"; a recap of the stations slept through would bury it. Returning
    // also keeps the pin out of chain projection, which is the whole reason
    // pins live outside the chain.
    for (final pin in overshootStations) {
      if (pin.contains(lat, lng) && _announcedArrivals.add(pin.id)) {
        return [
          Announcement(
            stationId: pin.id,
            kind: AnnouncementKind.overshoot,
            text: ClipKind.overshoot.render(
              pin.nameIn(language),
              language: language,
            ),
          ),
        ];
      }
    }

    final result = <Announcement>[];

    // A WALK PAIR IS ONE PLACE until the rider alights at its near half. Both
    // halves sit on the chain 205 m apart behind 450 m fences, so on the run
    // in to Dadar the FAR half reads as nearest for the last half kilometre,
    // which is a platform across a bridge from the one the train is drawing
    // into. Answering as the near half keeps every question below (approach,
    // arrival, projection) pointed at the platform the rider is actually
    // arriving at, and it is what makes the heads-up announcement fire on time
    // instead of the far half stealing it.
    var n = _nearestIndex(lat, lng);
    if (_behindItsWalkPair(n, lat, lng, accuracyM)) n -= 1;
    final nearest = chain[n];
    final nearestDist = nearest.distanceM(lat, lng);

    // How far along the chain has the train provably got? Inside the nearest
    // fence, or geometrically beyond it toward the next station, is DIRECT
    // evidence of being at or past that station. Otherwise the fix only says
    // "still approaching station n", and "so n - 1 must be behind us" is an
    // ELIMINATIVE inference: true on a straight chain, false wherever the
    // chain doubles back. On the 18 Jul ride a single 143 m fix in the Thane
    // creek V read nearest-to-Kalwa and the inference spoke "You have passed
    // Thane" 2.5 minutes before the train got there, which then deduped the
    // real interchange arrival into silence.
    final inside = nearestDist <= nearest.radiusM;
    final direct = inside || _isPast(lat, lng, n);
    final int passedIndex = direct ? n : n - 1;

    if (_reachedIndex < 0) {
      // First fix only localizes: boarding mid-chain must not replay every
      // station already behind the rider.
      _reachedIndex = passedIndex;
    } else {
      var claimIndex = passedIndex;

      // An eliminative claim may only pass stations the fix is provably
      // beyond along each station's OWN inbound leg. Nearest-station
      // assignment cannot be trusted for this: the real Digha to Thane track
      // curves so close to Kalwa that honest on-track fixes read "nearest
      // Kalwa", and by chain order that would pass Thane while the train is
      // still approaching it. The per-station check is immune to a wrong
      // nearest choice because it asks about the station being passed, not
      // the one the fix happens to sit closest to. (The direct case needs no
      // such walk: a train provably at station n has, by the chain's order,
      // passed every station before n.)
      if (!direct) {
        var confirmed = _reachedIndex;
        for (var i = _reachedIndex + 1; i <= claimIndex; i++) {
          if (!_isPast(lat, lng, i)) break;
          confirmed = i;
        }
        claimIndex = confirmed;
      }

      // Corroboration rule: a direct claim advances immediately (catch-up
      // latency arms the wake ladder, so it must not wait), but an
      // eliminative claim is held until the next usable fix also says the
      // train has moved on. A contradicting fix discards the held claim
      // instead of speaking it. Cost measured on the 18 Jul logs: the one
      // legitimate eliminative catch-up (Rabale) moved 13 s later; the false
      // Thane announcement disappeared.
      if (claimIndex > _reachedIndex && !direct) {
        if (_pendingEliminativeIndex < 0 ||
            claimIndex < _pendingEliminativeIndex) {
          // First sighting, or a fix that walks the claim BACK. Neither is
          // corroboration: hold (the weaker claim, so a wobble cannot
          // ratchet the train forward) and wait for the next usable fix.
          _pendingEliminativeIndex = claimIndex;
          claimIndex = _reachedIndex;
        } else {
          // The new fix independently proves the train is at or beyond the
          // held claim, so it corroborates. Speak the FRESHER index: it is
          // the better-evidenced position, and it has already passed the
          // per-station _isPast test above.
          _pendingEliminativeIndex = -1;
        }
      } else {
        _pendingEliminativeIndex = -1;
      }

      // Backstop: any un-announced station the train has moved past since the
      // last fix (a fence the native engine jumped) is announced now, late,
      // and in the past tense: by the time this fires the train is provably
      // beyond the station, and on the 13 Jul ride "Now approaching Kalwa"
      // spoken three kilometres past Kalwa read as a live claim and misled.
      // The station the fix is actually inside is left to the fence arrival
      // below, which speaks the normal text.
      for (var i = _reachedIndex + 1; i <= claimIndex; i++) {
        if (i == n && inside) continue;
        if (_announcedArrivals.add(chain[i].id)) {
          result.add(_passed(chain[i]));
        }
      }
      if (claimIndex > _reachedIndex) {
        _reachedIndex = claimIndex;
      }
    }

    // Standing in a station, or between two. Set from THIS fix and only from a
    // usable one: the accuracy gate above has already returned, so a blackout
    // leaves the last known answer rather than claiming the rider left the
    // platform. Compared against the reached index so it can never disagree
    // with the chain's own idea of where the train is.
    _atReachedStation = inside && n == _reachedIndex;

    // Normal fence arrival for the nearest station.
    if (nearestDist <= nearest.radiusM && _announcedArrivals.add(nearest.id)) {
      result.add(_arrival(nearest));
    }

    // Heads-up ping when approaching a two-stage station's outer fence.
    final approachRadius = approachRadiusM[nearest.id];
    if (approachRadius != null &&
        nearestDist > nearest.radiusM &&
        nearestDist <= approachRadius &&
        !_announcedArrivals.contains(nearest.id) &&
        _announcedApproaches.add(nearest.id)) {
      result.add(
        Announcement(
          stationId: nearest.id,
          kind: AnnouncementKind.approach,
          text: ClipKind.approach.render(
            nearest.nameIn(language),
            language: language,
          ),
        ),
      );
    }

    return result;
  }

  /// Arrival announcement for [station].
  ///
  /// The overshoot warning is no longer decided here. Since the chain ends at
  /// the destination (the pins live in [overshootStations], matched by
  /// proximity at the top of [onFix]), no chain station is ever past the
  /// destination, so the old in-chain overshoot branch was dead.
  Announcement _arrival(Station station) {
    return Announcement(
      stationId: station.id,
      kind: AnnouncementKind.arrival,
      text:
          arrivalAnnouncements[station.id] ??
          ClipKind.approach.render(
            station.nameIn(language),
            language: language,
          ),
    );
  }

  /// Late catch-up for a station the train is provably beyond.
  Announcement _passed(Station station) {
    return Announcement(
      stationId: station.id,
      kind: AnnouncementKind.passed,
      text: ClipKind.passed.render(
        station.nameIn(language),
        language: language,
      ),
    );
  }

  /// Whether [index] is the far half of a walk interchange whose near half the
  /// train has not reached yet, and so cannot be claimed by any evidence.
  ///
  /// Asks about the ARRIVAL, not about proximity: a rider standing on the
  /// Dadar Central platform is already well inside the Dadar Western fence,
  /// and 205 m of platform offset is not a train ride. The block lifts the
  /// moment the near half is announced, which is when the rider gets off and
  /// starts walking, and from there the pair announces in chain order.
  bool _behindItsWalkPair(int index, double lat, double lng, double accuracyM) {
    if (index == 0) return false;
    final nearId = chain[index - 1].id;
    if (!walkInterchangeStationIds.contains(nearId)) return false;
    // Still on the train, or on the near platform: the pair is the near half.
    if (!_announcedArrivals.contains(nearId)) return true;
    return !_hasCrossedTo(index, nearId, lat, lng, accuracyM);
  }

  /// Whether the rider has crossed the rails to the far half at [index].
  ///
  /// True with no line curated for the pair, which is the older behaviour: the
  /// far half follows the near one straight away. False, not true, when the
  /// fix cannot answer (too coarse, or too far from the pair), because an
  /// unanswered question must not be read as "they have crossed".
  bool _hasCrossedTo(
    int index,
    String nearId,
    double lat,
    double lng,
    double accuracyM,
  ) {
    final rails = walkCrossings[nearId];
    if (rails == null || rails.length < 2) return true;
    if (accuracyM > walkCrossingMaxAccuracyM) return false;
    final far = chain[index];
    if (far.distanceM(lat, lng) > walkCrossingRangeM) return false;

    // Which side "across" is, taken from the station nodes rather than stored,
    // so one line serves both directions: the rails are the same either way
    // and only the far half changes.
    final farSide = _sideOfRails(rails, far.lat, far.lng);
    if (farSide == 0) return true;
    final toward = farSide < 0 ? -1.0 : 1.0;
    return (_sideOfRails(rails, lat, lng) - toward * walkCrossingBoundaryM) *
            toward >=
        0;
  }

  /// Signed distance in metres from the rails, positive to the left of the
  /// line's own direction. Sign alone is what matters, and it is compared
  /// against the far station's, so which way the points were listed is
  /// irrelevant.
  ///
  /// Uses the first and last point: the four Dadar points sit within 8 m of
  /// their own end-to-end line over 358 m, so the run is a straight rail and
  /// the ends describe it.
  double _sideOfRails(List<(double, double)> rails, double lat, double lng) {
    final (aLat, aLng) = rails.first;
    final (bLat, bLng) = rails.last;
    final cosLat = math.cos(_toRad(aLat));
    final bx = (bLng - aLng) * cosLat * _metresPerDegree;
    final by = (bLat - aLat) * _metresPerDegree;
    final px = (lng - aLng) * cosLat * _metresPerDegree;
    final py = (lat - aLat) * _metresPerDegree;
    final length = math.sqrt(bx * bx + by * by);
    if (length == 0) return 0;
    return (bx * py - by * px) / length;
  }

  /// Index of the chain station nearest the given fix.
  int _nearestIndex(double lat, double lng) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < chain.length; i++) {
      final d = chain[i].distanceM(lat, lng);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// Whether the fix lies beyond station [index], i.e. the train has carried on
  /// past it rather than still being on its way in.
  ///
  /// Projects onto the INBOUND leg (previous station -> this one), because that
  /// is the heading the train is travelling on when it reaches this station, so
  /// "beyond it" means "further along that same heading". Projecting onto the
  /// outbound leg (this -> next) instead breaks wherever the chain doubles back:
  /// at the Thane interchange the train arrives from the east on the Central line
  /// and leaves to the east again toward Digha, so a fix still short of Thane
  /// lies on the same side as the next station and reads as past it. On the
  /// 12 Jul ride that fired the full "you have reached Thane" interchange script
  /// 1.19 km early on both phones, and left the real arrival silent.
  ///
  /// Uses an equirectangular projection so longitude and latitude are comparable,
  /// then a dot product between the leg and the station->fix vectors.
  bool _isPast(double lat, double lng, int index) {
    final here = chain[index];

    // The chain origin has no inbound leg, so fall back to its outbound one.
    // Safe: the rider boards at the origin, and the first fix only localizes.
    //
    // A walk pair's inbound leg is the WALK, and that is the right leg to use
    // for it: the far half is only genuinely behind a rider who has crossed
    // the bridge. It reads correctly here because the far half is unreachable
    // until the near one is announced (see [_behindItsWalkPair]), so this is
    // never asked about a train that is merely approaching the pair.
    final Station from;
    final Station to;
    if (index > 0) {
      from = chain[index - 1];
      to = here;
    } else if (chain.length > 1) {
      from = here;
      to = chain[index + 1];
    } else {
      return false;
    }

    final cosLat = math.cos(_toRad(here.lat));
    final legX = (to.lng - from.lng) * cosLat;
    final legY = to.lat - from.lat;
    final toFixX = (lng - here.lng) * cosLat;
    final toFixY = lat - here.lat;
    return (legX * toFixX + legY * toFixY) > 0;
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;
}
