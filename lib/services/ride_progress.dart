import 'dart:math' as math;

import '../models/station.dart';

/// The kind of announcement an [Announcement] represents.
enum AnnouncementKind { approach, arrival, overshoot }

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
    // fence, or geometrically beyond it toward the next station, means it is at
    // or past that station; otherwise it is still approaching it (so the
    // previous station is the furthest reached).
    final int passedIndex;
    if (nearestDist <= nearest.radiusM || _isPast(lat, lng, n)) {
      passedIndex = n;
    } else {
      passedIndex = n - 1;
    }

    if (_reachedIndex < 0) {
      // First fix only localizes: boarding mid-chain must not replay every
      // station already behind the rider.
      _reachedIndex = passedIndex;
    } else {
      // Backstop: any un-announced station the train has moved past since the
      // last fix (a fence the native engine jumped) is announced now, late.
      for (var i = _reachedIndex + 1; i <= passedIndex; i++) {
        if (_announcedArrivals.add(chain[i].id)) {
          result.add(_arrival(chain[i]));
        }
      }
      if (passedIndex > _reachedIndex) {
        _reachedIndex = passedIndex;
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
    final index = chain.indexOf(station);
    final destinationIndex =
        chain.indexWhere((s) => s.id == destinationStationId);
    if (index > destinationIndex) {
      return Announcement(
        stationId: station.id,
        kind: AnnouncementKind.overshoot,
        text: 'You have passed your stop. Please alight at the next station.',
      );
    }
    return Announcement(
      stationId: station.id,
      kind: AnnouncementKind.arrival,
      text: arrivalAnnouncements[station.id] ?? 'Now approaching ${station.name}.',
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
