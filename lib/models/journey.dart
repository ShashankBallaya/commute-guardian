import 'station.dart';

/// A point on a [Journey] where the rider has to change trains.
class Interchange {
  const Interchange({
    required this.stationId,
    required this.fromLineId,
    required this.toLineId,
    required this.toLineShortName,
    required this.towardsStationName,
    required this.isSameNamedService,
    this.walkToStationName,
    this.platform,
  });

  /// Where the rider gets OFF the current train. For a walk interchange this is
  /// the near side of the foot overbridge; boarding happens at
  /// [walkToStationName].
  final String stationId;

  /// Spoken name of the station across the foot overbridge to walk to (Dadar
  /// Central alight, walk to `Dadar Western`). Null for an ordinary
  /// same-station change.
  final String? walkToStationName;
  final String fromLineId;
  final String toLineId;

  /// Spoken name of the line being changed ONTO, e.g. `Trans Harbour`.
  final String toLineShortName;

  /// Spoken name of the station the onward line ends at in the direction of
  /// travel, e.g. `Karjat`. The only way to describe a change when both lines
  /// share a name (see [isSameNamedService]).
  final String towardsStationName;

  /// True when both lines are spoken the same way (Kasara branch onto the
  /// Karjat branch: both are just "Central"). "Change here to the Central line"
  /// while sitting on a Central train is nonsense, so these announce by
  /// direction instead.
  final bool isSameNamedService;

  /// Spoken platform to walk to, e.g. `9, 10, or 10 A`, when known. Null means
  /// the announcement names the change but not the platform.
  final String? platform;
}

/// One rider's planned ride: the ordered stations it passes through, where the
/// rider gets off, and where they have to change trains.
///
/// This is what replaced the hardcoded Kalyan -> Digha constants. It is the
/// input `RideProgress` needs and nothing more: a [chain] to track progress
/// along, a [destinationStationId] to alight at, and the announcement config
/// derived from both.
class Journey {
  const Journey({
    required this.chain,
    required this.originStationId,
    required this.destinationStationId,
    required this.overshootStations,
    required this.interchanges,
  });

  /// Every station the ride passes, in travel order, from the origin through to
  /// the destination.
  ///
  /// LINEAR BY CONTRACT, and it ends at the destination. The overshoot pins are
  /// deliberately NOT in here: past a terminus there can be more than one, they
  /// diverge geographically, and RideProgress projects position along this list
  /// by chain order. Feeding it a fork is the same shape as the 18 Jul false
  /// "You have passed Thane", where a fix near a doubled-back chain slot read
  /// as the train being a station further on than it was.
  final List<Station> chain;

  final String originStationId;

  /// Where the rider alights. Announced as an arrival, not a passing ping.
  final String destinationStationId;

  /// The stations one stop past the destination: the safety net that still
  /// warns a rider who slept through the alight.
  ///
  /// Usually one. At a TERMINUS destination it is one per branch the train may
  /// run through onto, because which one it takes cannot be known from the plan
  /// (a Kalyan train continues to Kasara or to Karjat, or terminates). Empty
  /// only when nothing runs past the destination at all. These are matched by
  /// proximity, never by chain order.
  ///
  /// Full stations, not ids: they sit outside [chain], so nothing else can
  /// resolve their coordinates, and both the geofences and RideProgress's
  /// proximity test need them.
  final List<Station> overshootStations;

  List<String> get overshootStationIds =>
      [for (final station in overshootStations) station.id];

  final List<Interchange> interchanges;

  /// Radius in metres of the larger outer "approach" fence, by station id, for
  /// the points the rider has to ACT on: the destination and every interchange.
  /// These get a heads-up while there is still time to reach the doors; ordinary
  /// stations just get their single fence ping.
  Map<String, int> get approachRadiusM => {
        for (final interchange in interchanges) interchange.stationId: 1200,
        destinationStationId: 1000,
      };

  /// What to say on ARRIVING at each station that needs more than the default
  /// "Now approaching X" ping.
  ///
  /// Phase 1 copy, English only. Phase 2 localizes this to Hindi and Marathi,
  /// at which point it moves out of here and behind the station name lookup.
  Map<String, String> get arrivalAnnouncements {
    final byId = {for (final station in chain) station.id: station};
    final announcements = <String, String>{};

    for (final interchange in interchanges) {
      final name = byId[interchange.stationId]?.name ?? interchange.stationId;
      final platform = interchange.platform;
      final toPlatform =
          platform == null ? '' : 'go to platform number $platform, then ';
      final String text;
      if (interchange.walkToStationName != null) {
        text = 'You have reached $name. Get off the train and walk across to '
            '${interchange.walkToStationName}, then ${toPlatform}board the '
            '${interchange.toLineShortName} train towards '
            '${interchange.towardsStationName} to continue to your '
            'destination.';
      } else if (interchange.isSameNamedService) {
        text = 'You have reached $name. Change trains here. Get off the train, '
            '${toPlatform}board the train towards '
            '${interchange.towardsStationName} to continue to your '
            'destination.';
      } else {
        text = 'You have reached $name. Change here to the '
            '${interchange.toLineShortName} line. Get off the train, '
            '${toPlatform}board the ${interchange.toLineShortName} train to '
            'continue to your destination.';
      }
      announcements[interchange.stationId] = text;
    }

    final destination = byId[destinationStationId]?.name ?? destinationStationId;
    announcements[destinationStationId] =
        'You have arrived at your destination, $destination.';

    return announcements;
  }
}
