import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/journey_history.dart';
import '../services/ride_service_client.dart';

/// The running-ride half of the state model.
///
/// Where journey_providers.dart holds things that RECOMPUTE (see the
/// Journey/Ride distinction in CONTEXT.md), everything here describes a ride
/// that only the service isolate can know about. It cannot be derived, only
/// reported, so it is either read back from the shared store or received as an
/// event. See docs/design/riverpod-adoption.md.

/// The one door to the service isolate, owned by exactly one provider.
///
/// Created and started here rather than by a widget, so the subscription
/// outlives any screen and an activity recreation does not tear the bridge
/// down and put it back up.
final rideServiceClientProvider = Provider<RideServiceClient>((ref) {
  final client = RideServiceClient()..start();
  ref.onDispose(client.dispose);
  return client;
});

// ---------------------------------------------------------------------------
// The ride itself: store-backed, therefore recreation-proof
// ---------------------------------------------------------------------------

/// A ride the service is running right now.
///
/// THE INVARIANT: every field here is recoverable from the shared store alone.
/// That is what makes activity recreation a non-event rather than the blank
/// route of 15 Jul. Nothing may be added to this class that the store cannot
/// answer for after the process dies; transient signals belong in
/// [RideAlerts].
class LiveRide {
  const LiveRide({
    required this.originId,
    required this.destinationId,
    required this.destinationReached,
  });

  final String originId;
  final String destinationId;

  /// True only once the destination arrival announcement actually spoke.
  final bool destinationReached;
}

/// The running ride, or null when none is running.
///
/// build() reads the store, so a freshly recreated process gets the same
/// answer the dead one had, with no widget involved and no user action.
class LiveRideNotifier extends AsyncNotifier<LiveRide?> {
  @override
  Future<LiveRide?> build() {
    // The store is the seed; the event stream is only the low-latency path.
    // Without this subscription the projection would be correct on arrival and
    // then frozen, and the service ending a ride on its own (wind-down
    // auto-off) would leave the screen claiming a ride that stopped.
    final subscription =
        ref.watch(rideServiceClientProvider).events.listen((event) {
      if (event is RideEndedByService) unawaited(refresh());
    });
    ref.onDispose(subscription.cancel);
    return _readFromStore();
  }

  Future<LiveRide?> _readFromStore() async {
    final client = ref.read(rideServiceClientProvider);
    try {
      if (!await client.isRunning()) return null;
      final persisted = await client.readPersistedRide();
      final originId = persisted.originId;
      final destinationId = persisted.destinationId;
      // A running service with no ids in the store is a store race, not a
      // ride. Reporting no ride is the safe read: the screen falls back to
      // the normal GPS origin fill, exactly as it did before.
      if (originId == null || destinationId == null) return null;
      return LiveRide(
        originId: originId,
        destinationId: destinationId,
        destinationReached: persisted.destinationReached,
      );
    } catch (_) {
      // No service plumbing (widget tests) or a store race.
      return null;
    }
  }

  /// Re-reads the store. Called after starting or ending a ride, so the UI
  /// never holds an opinion about liveness that the store disagrees with.
  Future<void> refresh() async {
    state = AsyncData(await _readFromStore());
  }
}

final liveRideProvider =
    AsyncNotifierProvider<LiveRideNotifier, LiveRide?>(LiveRideNotifier.new);

/// Whether a ride is running at all. Loading counts as "not running", which is
/// what the screen assumed before this provider existed.
final isRideRunningProvider = Provider<bool>(
  (ref) => ref.watch(liveRideProvider).valueOrNull != null,
);

// ---------------------------------------------------------------------------
// Alerts: deliberately NOT store-backed
// ---------------------------------------------------------------------------

/// What the app is currently asking the rider for.
///
/// DELIBERATELY TRANSIENT, and kept out of [LiveRide] for that reason. The
/// service does not persist these, so after an activity recreation both come
/// back false: a ladder that is mid-climb would lose its on-screen "I'm awake"
/// button until the next rung's event arrives. That is exactly the behaviour
/// before this refactor, so it is a known gap rather than a regression, and it
/// is honest about which half of the state model recovers.
///
/// Closing it is a SERVICE-SIDE change (persist the two flags next to the
/// sendDataToMain that already announces them), which is additive and cheap,
/// but it belongs to whoever builds the Active Journey screen, not to a state
/// migration.
class RideAlerts {
  const RideAlerts({this.wakeLadderLive = false, this.windDownLive = false});

  /// The wake ladder is asking to be acknowledged. Drives the "I'm awake"
  /// button and the native media session.
  final bool wakeLadderLive;

  /// The post-arrival auto-off countdown is running.
  final bool windDownLive;
}

class RideAlertsNotifier extends Notifier<RideAlerts> {
  @override
  RideAlerts build() {
    final subscription =
        ref.watch(rideServiceClientProvider).events.listen(_onEvent);
    ref.onDispose(subscription.cancel);
    return const RideAlerts();
  }

  void _onEvent(ServiceEvent event) {
    switch (event) {
      case WakeLadderChanged(:final live):
        state = RideAlerts(
          wakeLadderLive: live,
          windDownLive: state.windDownLive,
        );
        // Claim media buttons exactly while a ladder is live, so the rider's
        // earphone taps keep controlling their music the rest of the time.
        unawaited(ref.read(rideServiceClientProvider).setMediaSession(live));
      case WindDownChanged(:final live):
        state = RideAlerts(
          wakeLadderLive: state.wakeLadderLive,
          windDownLive: live,
        );
      case ToneCommanded(:final command, :final volume):
        unawaited(
          ref.read(rideServiceClientProvider).sendNativeTone(command, volume),
        );
      case ServiceLogged():
      case RideEndedByService():
      case ServiceFix():
        // Not alerts. The screen handles these.
        break;
    }
  }

  /// Clears both alerts as a ride tears down.
  ///
  /// The dying service isolate announces this too, but a teardown race must
  /// not leave a phantom "I'm awake" button or a claimed media session behind.
  Future<void> standDown() async {
    final hadLadder = state.wakeLadderLive;
    state = const RideAlerts();
    if (hadLadder) {
      await ref.read(rideServiceClientProvider).setMediaSession(false);
    }
  }
}

final rideAlertsProvider =
    NotifierProvider<RideAlertsNotifier, RideAlerts>(RideAlertsNotifier.new);

// ---------------------------------------------------------------------------
// Finished rides
// ---------------------------------------------------------------------------

/// The on-device journey history.
///
/// Opened lazily: the real factory needs path_provider, so a screen that never
/// looks at history never touches that channel. Tests override this with an
/// in-memory database.
///
/// UI ISOLATE ONLY. The service isolate does not open this file and never
/// writes a row; rides are recorded from the screen's teardown path, on this
/// connection. Worth stating because an earlier draft of
/// docs/design/riverpod-adoption.md claimed the opposite and drew a design
/// conclusion from it.
final journeyHistoryDbProvider = Provider<JourneyHistoryDatabase>((ref) {
  final db = JourneyHistoryDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Finished rides, newest first.
///
/// autoDispose is the whole design: the history sheet is a modal, so this
/// lives exactly as long as the sheet is open and re-runs the query the next
/// time it opens. That is the "reads fresh on every open" behaviour the sheet
/// already had, with nothing left to remember. No invalidation wiring, and no
/// permanent query subscription for a screen that is rarely on.
final rideHistoryProvider =
    FutureProvider.autoDispose<List<JourneyRecord>>((ref) {
  return ref.watch(journeyHistoryDbProvider).recent();
});

/// Distinct destinations by most recent ride, at most three.
///
/// This is what fills Screen 1's cards for a rider who never saves a route,
/// which is the whole point of the home screen's middle state: a non-saver
/// keeps the two-tap start forever. A destination someone rides daily appears
/// once, not once per ride.
///
/// An EMPTY list means no journey has ever completed, which is exactly the
/// first-run signal Screen 1 keys its empty state to. Screen 1's three states
/// hang on journeys COMPLETED, never on routes saved.
final recentDestinationsProvider =
    FutureProvider.autoDispose<List<JourneyRecord>>((ref) {
  return ref.watch(journeyHistoryDbProvider).recentDestinations();
});
