import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/station_repository.dart';
import '../models/journey.dart';
import '../models/station.dart';

/// The pre-ride half of the state model: the station network, what the rider
/// has picked, where they are, and the journey those imply.
///
/// Everything here is DERIVABLE. Kill the process and it all recomputes from
/// the station data plus two ids, which is why none of it is persisted and
/// none of it needs the service isolate. The unrecoverable half (the running
/// ride) is a separate provider with a different shape, seeded from the
/// service store. See docs/design/riverpod-adoption.md.

// ---------------------------------------------------------------------------
// The station network
// ---------------------------------------------------------------------------

/// The parsed 127-station network. Loaded once per process.
///
/// The service isolate loads its own copy; providers do not cross isolates and
/// this one has no idea the other exists.
final stationRepositoryProvider = FutureProvider<StationRepository>(
  (ref) => StationRepository.load(),
);

/// The pickers' list, sorted once rather than on every rebuild.
final stationsAlphabeticalProvider = Provider<List<Station>>((ref) {
  final repo = ref.watch(stationRepositoryProvider).valueOrNull;
  if (repo == null) return const [];
  return repo.stationsById.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
});

// ---------------------------------------------------------------------------
// What the rider has picked
// ---------------------------------------------------------------------------

/// The origin and destination the rider has chosen, and nothing else.
///
/// Two nullable ids is the whole of it: a draft is not a Journey, it is what a
/// Journey gets planned FROM.
class JourneyDraft {
  const JourneyDraft({this.originId, this.destinationId});

  final String? originId;
  final String? destinationId;
}

class JourneyDraftNotifier extends Notifier<JourneyDraft> {
  @override
  JourneyDraft build() => const JourneyDraft();

  /// Explicit setters rather than copyWith: both fields are nullable and both
  /// are legitimately cleared, which copyWith cannot express without a
  /// sentinel.
  void setOrigin(String? id) =>
      state = JourneyDraft(originId: id, destinationId: state.destinationId);

  void setDestination(String? id) =>
      state = JourneyDraft(originId: state.originId, destinationId: id);

  /// After a ride ends: the next one usually starts where the last finished,
  /// so the origin carries over (when the ride provably got there) and the
  /// destination is always cleared for a fresh pick.
  void resetAfterRide({String? originId}) =>
      state = JourneyDraft(originId: originId);

  /// Fills the origin only when the rider has not chosen one. A fix must never
  /// overwrite a deliberate choice.
  bool defaultOriginTo(String stationId) {
    if (state.originId != null) return false;
    setOrigin(stationId);
    return true;
  }
}

final journeyDraftProvider =
    NotifierProvider<JourneyDraftNotifier, JourneyDraft>(
      JourneyDraftNotifier.new,
    );

// ---------------------------------------------------------------------------
// The journey those imply
// ---------------------------------------------------------------------------

/// A planned journey, or why the draft cannot become one. Both null before the
/// rider has picked both ends.
class PlannedJourney {
  const PlannedJourney({this.journey, this.error});

  final Journey? journey;
  final String? error;
}

/// The plan. A pure function of the draft and the station data, so it is a
/// plain Provider: there is no state to hold, nothing to persist, and nothing
/// that process death could lose. Recomputes whenever either input changes,
/// which is what the old _replan() call scattered through the widget did by
/// hand.
final plannedJourneyProvider = Provider<PlannedJourney>((ref) {
  final repo = ref.watch(stationRepositoryProvider).valueOrNull;
  final draft = ref.watch(journeyDraftProvider);
  final originId = draft.originId;
  final destinationId = draft.destinationId;
  if (repo == null || originId == null || destinationId == null) {
    return const PlannedJourney();
  }
  try {
    return PlannedJourney(
      journey: repo.planner.plan(
        originId: originId,
        destinationId: destinationId,
      ),
    );
  } catch (error) {
    return PlannedJourney(
      error: error is ArgumentError
          ? '${error.message}'
          : 'Cannot plan this ride.',
    );
  }
});

// ---------------------------------------------------------------------------
// Where the rider is
// ---------------------------------------------------------------------------

/// What the status chip currently knows about where the rider is.
enum GpsState { locating, located, unavailable }

class NearestStation {
  const NearestStation(this.state, {this.stationName});

  final GpsState state;
  final String? stationName;
}

/// How to get a one-shot fix. A provider so tests can override it: the real
/// plugin's channel never answers under the widget-test binding (it neither
/// resolves nor throws), which would pin the chip on "Locating..." forever.
typedef FixAcquirer = Future<fl.Location> Function();

final fixAcquirerProvider = Provider<FixAcquirer>((ref) => _acquireFixLive);

Future<fl.Location> _acquireFixLive() async {
  if (!await fl.FlLocation.isLocationServicesEnabled) {
    throw StateError('Location services are off.');
  }
  // Bounded: without a limit an indoor acquisition can wait forever.
  return fl.FlLocation.getLocation(
    accuracy: fl.LocationAccuracy.balanced,
    timeLimit: const Duration(seconds: 8),
  );
}

class NearestStationNotifier extends Notifier<NearestStation> {
  /// Worst fix we will name a station from. A fix vaguer than this says
  /// nothing useful about which platform the rider is on.
  static const maxOriginAccuracyM = 500.0;

  /// How far from a station the rider can be and still be plausibly setting
  /// off from it. Generous on purpose (people open the app on the walk in),
  /// but it rules out a fix that is not near the network at all.
  static const maxOriginDistanceM = 3000.0;

  @override
  NearestStation build() => const NearestStation(GpsState.locating);

  /// A ride starts where the rider is standing, so default the origin to the
  /// nearest station rather than making them find it in a list of 127.
  Future<void> locate() async {
    if (ref.read(stationRepositoryProvider).valueOrNull == null) return;
    // Shown while acquiring, so the chip never keeps claiming an old position
    // during a slow fix (it sat on the pre-ride station through the whole
    // post-ride acquisition on the 13 Jul bench).
    state = const NearestStation(GpsState.locating);
    try {
      final location = await ref.read(fixAcquirerProvider)();
      applyFix(location.latitude, location.longitude, location.accuracy);
    } catch (_) {
      // No fix in time. The picker is the fallback, so this is not an error.
      state = const NearestStation(GpsState.unavailable);
    }
  }

  /// Names the nearest station from a fix: updates the chip, and fills the
  /// origin when the rider has not picked one. The ONE GATE for every fix
  /// source, live GPS or the service stream. Returns whether the fix could
  /// name a station.
  ///
  /// Only from a fix worth trusting. The nearest station to a vague fix is a
  /// guess, and a wrong guess here silently plans a ride the rider is not on,
  /// which is worse than not guessing: leave the field empty and let them
  /// pick. The thresholds are judgement calls rather than measurements.
  bool applyFix(double lat, double lng, double accuracyM) {
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    if (repo == null) return false;
    if (accuracyM > maxOriginAccuracyM) {
      state = const NearestStation(GpsState.unavailable);
      return false;
    }

    final nearest = repo.nearestStation(lat, lng);
    if (repo.distanceToM(nearest, lat, lng) > maxOriginDistanceM) {
      // Position known but nowhere near the network. The chip has no station
      // to name, and admitting that beats keeping a stale one on screen.
      state = const NearestStation(GpsState.unavailable);
      return false;
    }

    state = NearestStation(GpsState.located, stationName: nearest.name);
    ref.read(journeyDraftProvider.notifier).defaultOriginTo(nearest.id);
    return true;
  }
}

final nearestStationProvider =
    NotifierProvider<NearestStationNotifier, NearestStation>(
      NearestStationNotifier.new,
    );
