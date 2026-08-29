import '../services/announcement_templates.dart';
import '../services/spoken_copy.dart';
import 'app_settings.dart';
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
    this.walkCrossing,
    this.platform,
  });

  /// Where the rider gets OFF the current train. For a walk interchange this is
  /// the near side of the foot overbridge; boarding happens at
  /// [walkToStationName].
  final String stationId;

  /// Spoken name of the station across the foot overbridge to walk to (Dadar
  /// Central alight, walk to `Dadar Western`). Null for an ordinary
  /// same-station change.
  ///
  /// A [SpokenName] rather than a string because the planner resolves it at
  /// Start, and the language the ride is announced in can change after that.
  final SpokenName? walkToStationName;

  /// The rails the rider physically crosses to reach [walkToStationName], as
  /// an ordered run of points along the track. Null for an ordinary
  /// same-station change, and null for a walk pair with no line curated yet.
  ///
  /// It exists because proximity cannot tell the two halves of a walk pair
  /// apart: their fences are 450 m and their centres 207 m, and on the 28 Aug
  /// 2026 ride the phone never came within 88 m of the Dadar Western node
  /// because the rider waited at the south end of the platform. Which SIDE of
  /// the rails the rider stands on separates them with nothing in between.
  final List<(double, double)>? walkCrossing;

  final String fromLineId;
  final String toLineId;

  /// Spoken name of the line being changed ONTO, e.g. `Trans Harbour`.
  final String toLineShortName;

  /// Spoken name of the station the onward line ends at in the direction of
  /// travel, e.g. `Karjat`. The only way to describe a change when both lines
  /// share a name (see [isSameNamedService]).
  final SpokenName towardsStationName;

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
    required this.wrongWayStations,
    required this.interchanges,
    required this.requestedDestinationId,
    this.walkOnStationName,
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
  ///
  /// THE PLANNER MAY CHOOSE THIS, and it is not always what the rider tapped.
  /// Both halves of a foot overbridge are one place to a rider, so asking for
  /// Prabhadevi from a Central train plans a ride to Parel and a walk across.
  /// [requestedDestinationId] is what they asked for; this is the geometry:
  /// the chain ends here, the geofences sit here, and the arrival is announced
  /// here, because this is the platform they have to be standing on.
  final String destinationStationId;

  /// The station the rider actually picked.
  ///
  /// Equal to [destinationStationId] on almost every ride. It differs only
  /// across a foot overbridge, and when it differs the rider has to be TOLD,
  /// which is the whole reason this field exists: until 27 Aug 2026 the
  /// substitution was silent, and a rider who asked for Prabhadevi was ridden
  /// to Parel, told "Parel", and left to work out the rest on a platform.
  ///
  /// It is also the id that gets PERSISTED and re-planned. Storing the
  /// resolved one instead loses the walk: replanning Parel to Parel produces a
  /// journey with nothing to say, so a resumed or relaunched ride would fall
  /// silent again exactly where the first one spoke.
  final String requestedDestinationId;

  /// Where the rider walks to after alighting, or null when they asked for the
  /// station the ride actually ends at.
  String? get walkOnStationId => requestedDestinationId == destinationStationId
      ? null
      : requestedDestinationId;

  /// Spoken name of that station, or null when there is no walk.
  ///
  /// Carried rather than looked up because the walk-on station is NOT on
  /// [chain]: the chain ends at the platform the rider alights on, so nothing
  /// else in this object can resolve the far side of the bridge. A
  /// [SpokenName] for the same reason [Interchange.walkToStationName] is one:
  /// the planner resolves it at Start and the ride's language can change after
  /// that.
  final SpokenName? walkOnStationName;

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

  List<String> get overshootStationIds => [
    for (final station in overshootStations) station.id,
  ];

  /// The stations one stop BEHIND the origin: where a rider who boarded on the
  /// wrong platform arrives first. The mirror image of [overshootStations], and
  /// deliberately the same shape.
  ///
  /// Usually one. At a TERMINUS origin it is one per branch running back out of
  /// it, because which one a wrongly boarded train takes cannot be known (a
  /// train leaving Kalyan the other way is a Kasara train or a Karjat train).
  /// Empty when nothing runs behind the origin at all, which is the honest
  /// answer at CSMT: there is no wrong direction to catch when the platform
  /// only faces one way.
  ///
  /// Outside [chain] for the same reason the overshoot pins are, and matched by
  /// proximity alone. They are evidence, not inference: a fix inside one says
  /// the rider is at a station the ride was never going to pass, which no
  /// amount of chain geometry can say wrongly. See [Journey.chain] for what
  /// projecting a non-chain station instead has already cost this app.
  final List<Station> wrongWayStations;

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
  /// "Now approaching X" ping, in the language the ride is spoken in.
  ///
  /// Was a getter with the English copy inline. It became a method taking a
  /// language when Phase 2 localized the spoken output, and the copy moved to
  /// SpokenCopy: none of these sentences has a clip (they are dynamic, so
  /// ADR 0001 leaves them on the device TTS floor forever), and the wording of
  /// a whole interchange script does not belong in a data model.
  ///
  /// THE DESTINATION LINE IS NOT WRITTEN HERE ANY MORE. It is
  /// [ClipKind.destination], the same template the clip pack was cut from,
  /// which it always had to be: this file used to carry its own copy of that
  /// sentence, and two copies of a byte-identical contract is the exact drift
  /// announcement_templates.dart exists to prevent.
  Map<String, String> arrivalAnnouncementsIn([
    AppLanguage language = AppLanguage.english,
  ]) {
    final copy = SpokenCopy(language);
    final byId = {for (final station in chain) station.id: station};
    final announcements = <String, String>{};

    for (final interchange in interchanges) {
      final station =
          byId[interchange.stationId]?.nameIn(language) ??
          interchange.stationId;
      final walkTo = interchange.walkToStationName;
      final String text;
      if (walkTo != null) {
        text = copy.interchangeWalk(
          station: station,
          walkTo: walkTo.inLanguage(language),
          line: interchange.toLineShortName,
          towards: interchange.towardsStationName.inLanguage(language),
          platform: interchange.platform,
        );
      } else if (interchange.isSameNamedService) {
        text = copy.interchangeSameService(
          station: station,
          towards: interchange.towardsStationName.inLanguage(language),
          platform: interchange.platform,
        );
      } else {
        text = copy.interchangeLine(
          station: station,
          line: interchange.toLineShortName,
          platform: interchange.platform,
        );
      }
      announcements[interchange.stationId] = text;

      // THE FAR HALF OF A WALK PAIR gets a line of its own, and it is a
      // confirmation rather than an arrival: the rider walked there, so the
      // default "Now approaching Dadar Western" is wrong twice over, in tense
      // and in what it is for. RideProgress holds it back until the rider is
      // provably across the rails, so hearing it means being on the right
      // platform.
      //
      // The far half is the chain slot straight after the near one. That is
      // the same invariant [RideProgress.walkInterchangeStationIds] rests on:
      // the planner puts both halves on the chain, in walking order.
      if (walkTo != null) {
        final near = chain.indexWhere((s) => s.id == interchange.stationId);
        if (near >= 0 && near + 1 < chain.length) {
          announcements[chain[near + 1].id] = copy.walkArrived(
            station: chain[near + 1].nameIn(language),
            line: interchange.toLineShortName,
            towards: interchange.towardsStationName.inLanguage(language),
          );
        }
      }
    }

    final destination =
        byId[destinationStationId]?.nameIn(language) ?? destinationStationId;
    var arrival = ClipKind.destination.render(destination, language: language);

    // THE WALK ACROSS, when the rider asked for the other end of a foot
    // overbridge. Said HERE rather than at the check-in because this is the
    // moment they step onto the platform and have to choose a direction.
    //
    // THE COST, accepted with eyes open: this sentence is appended to a
    // clip-backed one, so the byte-identical rule in ClipLibrary stops
    // matching and the whole arrival drops to the device TTS floor for this
    // ride. That is the right way round. A Sarvam voice saying only half of
    // what the rider needs is worse than a device voice saying all of it, and
    // it costs the voice on walk-on rides alone, never on an ordinary one.
    final walkOnId = walkOnStationId;
    if (walkOnId != null) {
      final walkOn = walkOnStationName?.inLanguage(language) ?? walkOnId;
      arrival = '$arrival ${copy.destinationAcrossBridge(walkOn)}';
    }
    announcements[destinationStationId] = arrival;

    return announcements;
  }
}
