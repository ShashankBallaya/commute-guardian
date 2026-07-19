import 'dart:math' as math;

import '../models/station.dart';

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
    this.approachRadiusM = const {},
    this.arrivalAnnouncements = const {},
    this.maxAccuracyM = 150,
  });

  final List<Station> chain;
  final String destinationStationId;
  final Map<String, int> approachRadiusM;
  final Map<String, String> arrivalAnnouncements;
  final double maxAccuracyM;

  final Set<String> _announcedArrivals = {};
  final Set<String> _announcedApproaches = {};

  /// Highest chain index the train has provably reached, or -1 until the first
  /// usable fix localizes it.
  int _reachedIndex = -1;

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

    final result = <Announcement>[];

    final n = _nearestIndex(lat, lng);
    final nearest = chain[n];
    final nearestDist = _distanceM(lat, lng, nearest.lat, nearest.lng);

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
        if (_pendingEliminativeIndex < 0) {
          _pendingEliminativeIndex = claimIndex;
          claimIndex = _reachedIndex;
        } else {
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

    // Normal fence arrival for the nearest station.
    if (nearestDist <= nearest.radiusM &&
        _announcedArrivals.add(nearest.id)) {
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
          text: 'Now approaching ${nearest.name}.',
        ),
      );
    }

    return result;
  }

  /// Arrival announcement for [station], or an overshoot warning when the
  /// station sits past the destination on the chain (the rider has gone too far).
  Announcement _arrival(Station station) {
    return _overshootFor(station) ??
        Announcement(
          stationId: station.id,
          kind: AnnouncementKind.arrival,
          text: arrivalAnnouncements[station.id] ??
              'Now approaching ${station.name}.',
        );
  }

  /// Late catch-up for a station the train is provably beyond. Overshoot beats
  /// the recap: past the destination the rider needs the warning, not history.
  Announcement _passed(Station station) {
    return _overshootFor(station) ??
        Announcement(
          stationId: station.id,
          kind: AnnouncementKind.passed,
          text: 'You have passed ${station.name}.',
        );
  }

  /// The overshoot warning for [station], or null when it is not past the
  /// destination. Names the station: this fires as the train reaches it, so
  /// "alight at the next station" would send the rider one stop too far.
  Announcement? _overshootFor(Station station) {
    final index = chain.indexOf(station);
    final destinationIndex =
        chain.indexWhere((s) => s.id == destinationStationId);
    if (index <= destinationIndex) return null;
    return Announcement(
      stationId: station.id,
      kind: AnnouncementKind.overshoot,
      // The reassurance breath ("It is alright.") is owner-approved copy,
      // synced with the Sarvam clip template: a rider who overslept must
      // not panic, and the TTS fallback must speak the same words as the
      // clip (tool/build_clip_pack.py keeps en-IN byte-identical to code).
      text: 'You have passed your stop. It is alright. Please alight here, '
          'at ${station.name}.',
    );
  }

  /// Index of the chain station nearest the given fix.
  int _nearestIndex(double lat, double lng) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < chain.length; i++) {
      final d = _distanceM(lat, lng, chain[i].lat, chain[i].lng);
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

  /// Great-circle distance in metres between two lat/lng points (haversine).
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
