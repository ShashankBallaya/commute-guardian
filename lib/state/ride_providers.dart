import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../services/ride_service_client.dart';
import '../services/wind_down.dart';

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
    this.reachedIndex = -1,
    this.atStation = false,
    this.alightStationId,
  });

  final String originId;
  final String destinationId;

  /// The station the rider will actually get off at, or null for the
  /// destination they picked.
  ///
  /// It differs only when the rider was carried past their stop and the app
  /// told them to alight at an overshoot pin. Screen 5 names this, so it is the
  /// difference between "You've arrived at Shahad" and the truth, which is that
  /// they are standing at Ambivli.
  final String? alightStationId;

  /// True only once the destination arrival announcement actually spoke.
  final bool destinationReached;

  /// How far along the chain the ride has provably got, or -1 before the first
  /// station. Comes from the service's own RideProgress, never re-derived here.
  final int reachedIndex;

  /// Standing IN the station at [reachedIndex] rather than past it on the way
  /// to the next. The engine has always known this; until the 9 Aug ride it
  /// had no way to say so, and Screen 4 drew a train sitting at a platform as
  /// though it had already left.
  final bool atStation;

  LiveRide withIndex(int index, {required bool atStation}) => LiveRide(
    originId: originId,
    destinationId: destinationId,
    destinationReached: destinationReached,
    reachedIndex: index,
    atStation: atStation,
    alightStationId: alightStationId,
  );

  LiveRide withAlightAt(String stationId) => LiveRide(
    originId: originId,
    destinationId: destinationId,
    destinationReached: destinationReached,
    reachedIndex: reachedIndex,
    atStation: atStation,
    alightStationId: stationId,
  );

  LiveRide get arrived => LiveRide(
    originId: originId,
    destinationId: destinationId,
    destinationReached: true,
    reachedIndex: reachedIndex,
    atStation: atStation,
    alightStationId: alightStationId,
  );
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
    final subscription = ref.watch(rideServiceClientProvider).events.listen((
      event,
    ) {
      if (event is RideEndedByService) unawaited(refresh());
      // Advance in place rather than re-reading the store: the store is the
      // seed and the survivor, the stream is the low-latency path, and a full
      // refresh on every station would make Screen 4 wait on a plugin read to
      // move a dot the service already told us about.
      if (event is RideProgressed) {
        final current = state.valueOrNull;
        if (current != null) {
          state = AsyncData(
            current.withIndex(
              event.reachedIndex,
              atStation: event.atStation,
            ),
          );
        }
      }
      // Advanced in place for the same reason progress is: Screen 5 opens on
      // this edge, and a store re-read would put a plugin call between the
      // rider standing on the platform and being told they have arrived.
      if (event is DestinationReached) {
        final current = state.valueOrNull;
        if (current != null && !current.destinationReached) {
          state = AsyncData(current.arrived);
        }
      }
      // The overshoot case, and the reason this is an event at all: the pin is
      // reached AFTER the arrival, so Screen 5 may already be open and naming
      // the wrong platform when it lands.
      if (event is AlightingAt) {
        final current = state.valueOrNull;
        if (current != null && current.alightStationId != event.stationId) {
          state = AsyncData(current.withAlightAt(event.stationId));
        }
      }
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
        reachedIndex: persisted.reachedIndex,
        atStation: persisted.atStation,
        alightStationId: persisted.alightStationId,
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

final liveRideProvider = AsyncNotifierProvider<LiveRideNotifier, LiveRide?>(
  LiveRideNotifier.new,
);

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
/// STORE-BACKED SINCE 30 JUL, and the bench that changed it is worth keeping.
/// These used to be deliberately transient, on the reasoning that a recreated
/// UI would lose the on-screen "I'm awake" button only "until the next rung's
/// event arrives". THAT REASONING WAS WRONG: liveness is edge-triggered, rungs
/// do not re-announce it, so the button never came back at all. Swiping the
/// app out of recents mid-alarm left a rider with a full-volume alarm and no
/// way to answer it, because the media session dies with the UI too. The
/// service now persists both flags next to the sendDataToMain that announces
/// them, and [build] seeds from the store.
class RideAlerts {
  const RideAlerts({
    this.wakeLadderLive = false,
    this.wakeRung = 0,
    this.wakeClimbing = true,
    this.windDownLive = false,
    this.windDownEndsAt,
    this.windDownWindow = WindDown.countdown,
  });

  /// The wake ladder is asking to be acknowledged. Drives the "I'm awake"
  /// button and the native media session.
  final bool wakeLadderLive;

  /// Which rung it is on, and whether it is still climbing. The alert screen's
  /// glow steps with the sound, so these travel with liveness rather than being
  /// guessed: a ladder climbing 1 to 3 never changes [wakeLadderLive].
  final int wakeRung;
  final bool wakeClimbing;

  /// The post-arrival auto-off countdown is running.
  final bool windDownLive;

  /// When it ends by itself, and the window that deadline was set from.
  /// Screen 5's ring is drawn from these, so they come from the service rather
  /// than being started fresh whenever this screen happens to appear.
  final DateTime? windDownEndsAt;
  final Duration windDownWindow;
}

class RideAlertsNotifier extends Notifier<RideAlerts> {
  @override
  RideAlerts build() {
    final subscription = ref
        .watch(rideServiceClientProvider)
        .events
        .listen(_onEvent);
    ref.onDispose(subscription.cancel);
    // The store read is async and this notifier is not, so the seed lands a
    // frame or two later. That is fine: false then true is a button appearing,
    // where the old behaviour was a button that never appeared.
    unawaited(_seedFromStore());
    return const RideAlerts();
  }

  /// Recovers liveness the UI was never present to hear announced.
  ///
  /// Re-claims the media session when a ladder turns out to be live, because
  /// the earphone tap is the ack a rider with the phone in their pocket
  /// actually uses, and it was released when the previous UI died.
  Future<void> _seedFromStore() async {
    final client = ref.read(rideServiceClientProvider);
    try {
      final persisted = await client.readPersistedRide();
      if (!persisted.wakeLadderLive && !persisted.windDownLive) return;
      // An event may have arrived while the read was in flight; it is fresher
      // than the store, so it wins.
      state = RideAlerts(
        wakeLadderLive: state.wakeLadderLive || persisted.wakeLadderLive,
        wakeRung: state.wakeLadderLive ? state.wakeRung : persisted.wakeRung,
        wakeClimbing: state.wakeLadderLive
            ? state.wakeClimbing
            : persisted.wakeClimbing,
        windDownLive: state.windDownLive || persisted.windDownLive,
        // The event, if one arrived while the read was in flight, is fresher.
        windDownEndsAt: state.windDownEndsAt ?? persisted.windDownEndsAt,
        windDownWindow: state.windDownEndsAt != null
            ? state.windDownWindow
            : persisted.windDownWindow,
      );
      if (state.wakeLadderLive) await client.setMediaSession(true);
    } catch (_) {
      // No service plumbing (widget tests) or a store race. The event stream
      // is still the primary path.
    }
  }

  /// Re-reads the store after the UI has been AWAY, and takes it as the truth.
  ///
  /// THE 9 AUG RIDE IS WHY THIS EXISTS. Every fact on this side arrives by
  /// `sendDataToMain`, which has no queue: an iOS UI isolate suspended in a
  /// pocket does not receive the event, it loses it. The rider acknowledged the
  /// alarm with an earphone tap at 20:52:54, the service stood the ladder down
  /// and said so, and this notifier never heard it. The alert screen pops on
  /// liveness going false, so it never left; and every press of "I'm awake"
  /// reached a service with no live ladder, which changes nothing, which sends
  /// nothing. Sixty-six presses are in that ride log. He force-stopped the app.
  ///
  /// AUTHORITATIVE, and that is the difference from [_seedFromStore]. That one
  /// ORs the store into the state, which can only ever turn an alarm ON: it was
  /// written for a UI that was newly born and could not hold a stale opinion. A
  /// resumed UI holds exactly that, so ORing would have left the alarm stuck
  /// on. The store is safe to trust here because the service writes it on every
  /// change, false as well as true (see `onWakeLadderLive` in the task
  /// handler), and any event arriving after this read is fresher and wins by
  /// simply landing later.
  Future<void> resync() async {
    final client = ref.read(rideServiceClientProvider);
    try {
      final persisted = await client.readPersistedRide();
      state = RideAlerts(
        wakeLadderLive: persisted.wakeLadderLive,
        wakeRung: persisted.wakeRung,
        wakeClimbing: persisted.wakeClimbing,
        windDownLive: persisted.windDownLive,
        windDownEndsAt: persisted.windDownEndsAt,
        windDownWindow: persisted.windDownWindow,
      );
      // Only ever CLAIMED here, never released. A ladder that stood down while
      // we were away released the session on the service side already, and a
      // release from here would be a new way for this screen to take the
      // earphone buttons off the rider's music.
      if (state.wakeLadderLive) await client.setMediaSession(true);
    } catch (_) {
      // No service plumbing (widget tests) or a store race. The event stream
      // is still the primary path.
    }
  }

  void _onEvent(ServiceEvent event) {
    switch (event) {
      case WakeLadderChanged(:final live, :final rung, :final climbing):
        state = RideAlerts(
          wakeLadderLive: live,
          wakeRung: rung,
          wakeClimbing: climbing,
          windDownLive: state.windDownLive,
          windDownEndsAt: state.windDownEndsAt,
          windDownWindow: state.windDownWindow,
        );
        // Claim media buttons exactly while a ladder is live, so the rider's
        // earphone taps keep controlling their music the rest of the time.
        unawaited(ref.read(rideServiceClientProvider).setMediaSession(live));
      case WindDownChanged(:final live, :final endsAt, :final window):
        state = RideAlerts(
          wakeLadderLive: state.wakeLadderLive,
          wakeRung: state.wakeRung,
          wakeClimbing: state.wakeClimbing,
          windDownLive: live,
          windDownEndsAt: endsAt,
          windDownWindow: window,
        );
      case ToneCommanded(:final command, :final volume):
        unawaited(
          ref.read(rideServiceClientProvider).sendNativeTone(command, volume),
        );
      case ServiceLogged():
      case RideEndedByService():
      case ServiceFix():
      case RideProgressed():
      case DestinationReached():
      case AlightingAt():
        // Not alerts. Progress belongs to LiveRide, which owns the projection;
        // duplicating it here would give Screen 4 two places to disagree with
        // itself about where the train is.
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

final rideAlertsProvider = NotifierProvider<RideAlertsNotifier, RideAlerts>(
  RideAlertsNotifier.new,
);

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
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
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
final rideHistoryProvider = FutureProvider.autoDispose<List<JourneyRecord>>((
  ref,
) {
  return ref.watch(appDatabaseProvider).recent();
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
      return ref.watch(appDatabaseProvider).recentDestinations();
    });

/// Routes the rider chose to keep, newest first.
///
/// Screen 1's third state hangs on this. autoDispose for the same reason as
/// the history query: these screens are visited, not watched.
final savedRoutesProvider = FutureProvider.autoDispose<List<SavedRoute>>((ref) {
  return ref.watch(appDatabaseProvider).allSavedRoutes();
});

/// Whether onboarding has been completed, which is what decides the app's
/// entry screen.
///
/// NOT autoDispose: it is read at launch and again after onboarding finishes,
/// and a rebuild in between must not re-query and flash the wrong screen.
final onboardingSeenProvider = FutureProvider<bool>((ref) {
  return ref.watch(appDatabaseProvider).hasSeenOnboarding();
});
