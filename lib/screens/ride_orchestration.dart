import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/app_settings.dart';
import '../models/journey.dart';
import '../services/permissions_gateway.dart';
import '../services/ride_service_client.dart';
import '../state/journey_providers.dart';
import '../state/readiness_providers.dart';
import '../state/ride_providers.dart';
import '../state/settings_providers.dart';
import 'arrival_screen.dart';
import 'destination_picker_screen.dart';
import 'history_screen.dart';
import 'onboarding_screen.dart' show permissionsGatewayProvider;
import 'preparing_flow.dart';
import 'settings_screen.dart';
import 'travel_mode_screen.dart';
import 'wake_alert_screen.dart';

/// Everything a screen needs in order to OWN a ride: the isolate subscription,
/// the start and stop paths, the history write, and the routes a ride opens.
///
/// This lived inside `_RideDebugScreenState` until 4 Aug 2026, which is what
/// made the Phase 2 entry-gate flip expensive rather than a one-line switch:
/// [HomeScreen]'s callbacks all bound to methods on the debug screen, so
/// pointing the app at Screen 1 would have yielded a home with no ride
/// orchestration behind it. It is a mixin rather than a controller because the
/// work is inseparably navigational (every path here pushes a route and awaits
/// what the rider does with it), and a Notifier holding a BuildContext would be
/// a worse lie than a mixin holding one honestly.
///
/// It deliberately does NOT own: the alert routing (that is
/// [rideAlertsProvider], which reaches the ladder without any screen's help),
/// liveness (the service store is the truth), or anything a bench needs. The
/// three debug-only couplings that used to be tangled in here are hooks:
/// [onOrchestrationLog], [sarvamGreeting] and [sarvamClips].
///
/// Both hosts must call [initOrchestration] from `initState` and
/// [disposeOrchestration] from `dispose`.
mixin RideOrchestration<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The only door to the service isolate, owned by a provider so it outlives
  /// this screen. Nothing in a widget file may touch FlutterForegroundTask
  /// directly; test/isolate_boundary_test.dart enforces it.
  RideServiceClient get service => ref.read(rideServiceClientProvider);

  late final StreamSubscription<ServiceEvent> _serviceEvents;

  /// WHICH RULE THE LADDER IS RUNNING, for Screen 4 to state. Not a control any
  /// more: the segmented toggle was removed on 11 Aug 2026 because nothing
  /// consumed it, and choosing the distance is a Guardian Plus surface.
  ///
  /// Still a field rather than a constant, because it is the seam Plus lands on
  /// and because it must survive the screen being popped and re-pushed within a
  /// ride. It must never become a second way to change leadTimeS.
  WakeChoice wakeChoice = WakeChoice.lastTwoStations;

  /// Whether the alarm is armed for THIS ride. Screen 4's shield pill owns it.
  ///
  /// A field on the host rather than a setting, which is the whole design: it
  /// resets to true at every Start (see [start]), and the SERVICE resets its
  /// own copy too, so neither side can remember an "off" into next week.
  bool wakeEnabled = true;

  /// The freshest fix streamed up from the running service. At ride end this is
  /// seconds old and free, so it names the rider's position instantly; a cold
  /// GPS acquisition indoors can hang instead (13 Jul bench).
  ({double lat, double lng, double accuracyM, DateTime at})? _lastServiceFix;

  /// A line the orchestration wants recorded. The debug screen puts it in its
  /// event log; product screens drop it, because no product screen has one.
  void onOrchestrationLog(String message) {}

  /// Debug bench flags, per Start, handed to the service through the store.
  /// False here keeps every product Start stock.
  bool get sarvamGreeting => false;
  bool get sarvamClips => false;

  /// Should a host that comes up mid-ride open Screen 4 by itself?
  ///
  /// TRUE FOR THE PRODUCT HOST, FALSE FOR THE DEBUG SCREEN, and the split is
  /// the whole point. A rider reopening the app after swiping it out of recents
  /// wants the ride they are on. Someone who has long-pressed the version line
  /// to reach the debug screen wants the BENCH, and covering it with Screen 4
  /// the instant it opens would make the wake ladder and wind-down benches
  /// unreachable during the only state they are worth running in.
  bool get resumesTravelModeScreen => false;

  /// The long press on Settings' version line, or null where there is nothing
  /// behind it (the debug screen itself, which is already there).
  ///
  /// Passed DOWN from the entry gate rather than reached for here, because the
  /// debug screen lives in main.dart and this file must not import it back.
  VoidCallback? get debugDoor => null;

  /// Watches for the app coming back to the foreground. See [_onResumed].
  AppLifecycleListener? _lifecycle;

  void initOrchestration() {
    _serviceEvents = service.events.listen(_onServiceEvent);
    // Forces the alerts notifier to exist before the first frame, so a ladder
    // event arriving between launch and the first build is not missed.
    ref.read(rideAlertsProvider);
    _watchForArrival();
    _watchForWakeLadder();
    _lifecycle = AppLifecycleListener(onResume: _onResumed);
    unawaited(_openingSequence());
  }

  /// THE APP HAD NO LIFECYCLE OBSERVER AT ALL until the 9 Aug ride, and this is
  /// the hole that left.
  ///
  /// Everything this side knows about a ride arrives through `sendDataToMain`,
  /// which has NO QUEUE. A UI isolate suspended in a pocket does not receive
  /// those events later; it never receives them. So the screen's picture of the
  /// ride is only as good as the last moment it was awake, which on this
  /// product is the moment before the rider put the phone away, i.e. before
  /// everything worth knowing happened.
  ///
  /// Two things went wrong on that ride and both are this:
  ///   The rider acked the alarm with an earphone tap. The ladder stood down,
  ///   the UI never heard, and the alert screen (which leaves on liveness going
  ///   false) trapped him. He pressed "I'm awake" 66 times against a service
  ///   with no ladder to stand down, and force-stopped the app.
  ///
  ///   The arrival screen never opened, on either phone, because
  ///   `destinationReached` was announced to a UI that was asleep.
  ///
  /// The store holds the right answer in both cases: the service writes every
  /// one of these facts as well as sending it. All that was missing was
  /// somebody asking again on the way back in.
  ///
  /// Both hosts carry this mixin and both will fire on a resume. That is
  /// harmless: both calls are idempotent reads, and the arrival latch is static
  /// precisely so two hosts cannot open two screens.
  void _onResumed() {
    if (!mounted) return;
    // Alerts FIRST. A stuck alert screen is the one state the rider cannot get
    // out of by themselves, and the whole ride is behind it.
    unawaited(ref.read(rideAlertsProvider.notifier).resync());
    unawaited(ref.read(liveRideProvider.notifier).refresh());
    // AND THE READINESS CARD, because a resume is the ONLY honest moment to
    // re-read it. Settings' Fix buttons send the rider to a system page, and
    // `openAppSettings` returns the instant that page launches rather than when
    // the rider comes back, so invalidating there re-reads the value they have
    // not changed yet. Coming back is the event, and this is where it lands.
    ref.invalidate(travelReadinessProvider);
  }

  /// Opens Screen 5 the moment the ride reaches its destination.
  ///
  /// THE LATCH IS STATIC, and an earlier draft's per-host `isCurrent` guard was
  /// WRONG in the exact case that matters. During a real ride the rider is on
  /// Screen 4, which is pushed OVER HomeShell, so HomeShell's route is not
  /// current and nothing would have opened Screen 5 at all. It passed on the
  /// bench only because the debug screen fired the arrival while its own route
  /// was on top. Pushing from a host that is not the visible route is correct:
  /// every host shares the root Navigator, so the arrival lands above whatever
  /// the rider is looking at, which is what an arrival should do.
  ///
  /// What the latch prevents is the real duplicate risk: two hosts carrying
  /// this mixin at once (the debug screen sits over HomeShell) both reacting to
  /// one arrival.
  void _watchForArrival() {
    ref.listenManual(liveRideProvider, (previous, next) {
      final arrived = next.valueOrNull?.destinationReached ?? false;
      final wasArrived = previous?.valueOrNull?.destinationReached ?? false;
      if (!arrived || wasArrived || _arrivalShown || !mounted) return;
      _arrivalShown = true;
      unawaited(showArrival());
    });
  }

  /// One arrival screen per ride, ACROSS HOSTS. Cleared when a ride starts, not
  /// when the screen closes: a rider who dismisses it and is still at the
  /// station should not have it spring back on the next fix.
  static bool _arrivalShown = false;

  /// Puts the wake alert in front of a sleeping rider, and takes it away when
  /// the ladder stands down.
  ///
  /// UNLIKE THE ARRIVAL, this latch is cleared when the ladder ends rather than
  /// when the ride starts: a chain can raise a ladder more than once (the
  /// approach ladder, then the destination's), and each one has to be answered.
  ///
  /// It opens whatever else is on screen, deliberately. The rider may be on
  /// Screen 4, or on the arrival screen after an overshoot; the alarm outranks
  /// all of it, which is the same rank the audio already uses.
  void _watchForWakeLadder() {
    ref.listenManual(rideAlertsProvider, (previous, next) {
      if (!mounted) return;
      if (next.wakeLadderLive && !_wakeAlertShown) {
        _wakeAlertShown = true;
        unawaited(showWakeAlert());
      } else if (!next.wakeLadderLive) {
        _wakeAlertShown = false;
      }
    });
  }

  static bool _wakeAlertShown = false;

  /// Clears both alert latches.
  ///
  /// They are static so two hosts cannot both open one alert, which means they
  /// outlive a widget the way a real ride does. In the app that is right: the
  /// wake latch clears when the ladder stands down, the arrival latch when the
  /// next ride starts. A test process shares them across every test in the
  /// file, so it has to say when a new session begins.
  @visibleForTesting
  static void resetAlertLatches() {
    _arrivalShown = false;
    _wakeAlertShown = false;
  }

  /// The wake alert, wired. The screen the whole product exists to put in front
  /// of a sleeping rider.
  ///
  /// IT DOES NOT OWN THE ACK, and that distinction is what makes it safe to
  /// add. The alarm is answered by the service; this screen is one more way to
  /// reach that, beside the notification button and the earphone tap that the
  /// 24 Jul bench proved. So it POPS ON LIVENESS, not on the press: if the
  /// rider answers with an earphone tap while this is showing, the ladder
  /// stands down and the screen leaves on its own.
  ///
  /// Back is refused by the screen itself while it is up (see WakeAlertScreen),
  /// because backing out would leave an alarm sounding with its on-screen ack
  /// gone.
  Future<void> showWakeAlert() async {
    if (!mounted) return;
    final live = ref.read(liveRideProvider).valueOrNull;
    final journey = ref.read(plannedJourneyProvider).journey;
    if (live == null) return;

    // "Thakurli passed 19:49": the rider's proof the app was awake while they
    // were not. Null before anything has been passed, which the screen expects.
    String? lastPassed;
    final reached = live.reachedIndex;
    if (journey != null && reached >= 0 && reached < journey.chain.length) {
      final at = TimeOfDay.fromDateTime(DateTime.now());
      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      lastPassed = '${journey.chain[reached].name} passed $hh:$mm';
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Consumer(
          builder: (context, ref, _) {
            final alerts = ref.watch(rideAlertsProvider);
            if (!alerts.wakeLadderLive) {
              // Answered, by whatever route. Leave on the next frame: popping
              // during a build is not allowed.
              //
              // pop(), NOT maybePop(). This screen wraps itself in
              // PopScope(canPop: false) to refuse a half-asleep back press, and
              // maybePop honours that refusal, so it would have been a no-op
              // here: the alarm answered by an earphone tap or the notification
              // would have left the rider staring at an alert screen for an
              // alarm that had already stopped, with no way out. The refusal is
              // aimed at the rider's back gesture, not at the ladder standing
              // down.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (routeContext.mounted) Navigator.of(routeContext).pop();
              });
            }
            return WakeAlertScreen(
              destinationName: stationName(live.destinationId),
              lastPassedLine: lastPassed,
              rung: alerts.wakeRung,
              climbing: alerts.wakeClimbing,
              onAcknowledge: service.ackWakeFromButton,
            );
          },
        ),
      ),
    );
  }

  void disposeOrchestration() {
    // The client itself is NOT disposed: it belongs to a provider that outlives
    // this screen, which is what stops an activity recreation from tearing the
    // bridge down and putting it back up.
    unawaited(_serviceEvents.cancel());
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Everything that has to wait for the station network, in order: restore a
  /// ride that is already running, then fill the origin from GPS. The order
  /// matters and is load bearing, see the note below.
  Future<void> _openingSequence() async {
    try {
      await ref.read(stationRepositoryProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    // Best-effort and deliberately NOT awaited: the foreground-task channel
    // never resolves under the widget-test binding (same trap as the location
    // fix), and the GPS fill must not hang behind it. When it does resolve
    // mid-ride, its explicit write wins over whatever the GPS fill guessed,
    // because the restore always writes and it writes as a PICK, which no
    // later fix may move.
    unawaited(_restoreRunningRide());
    await ref.read(nearestStationProvider.notifier).locate();
  }

  /// Rebuilds the pickers and route summary from the service store when the UI
  /// comes up with a ride already live. Android recreated the activity mid-ride
  /// on 15 Jul and the rebuilt screen showed a blank destination and no route
  /// while End journey was correctly offered; the service store has owned the
  /// truth about the running ride all along, the UI just never asked it.
  Future<void> _restoreRunningRide() async {
    final ride = await ref.read(liveRideProvider.future);
    if (ride == null || !mounted) return;
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    final origin = repo?.stationsById[ride.originId];
    final destination = repo?.stationsById[ride.destinationId];
    if (origin == null || destination == null) return;
    final draft = ref.read(journeyDraftProvider.notifier);
    draft.setOrigin(origin.id);
    draft.setDestination(destination.id);
    onOrchestrationLog('Restored the running ride from the service store.');

    // AND PUT THE RIDER BACK ON THE RIDE. Reported on device 11 Aug 2026: swipe
    // the app out of recents on Android and the service keeps running correctly,
    // but reopening lands on Home. The chain, the next station and End journey
    // are all somewhere the rider cannot reach, on a ride that is still running.
    //
    // The cause was narrow. showTravelMode() had exactly two callers and both of
    // them START a ride, so a UI that came up mid-ride restored the pickers
    // underneath and never opened the screen they feed. Restoring the DRAFT was
    // the 15 Jul fix for a blank destination; it was never the whole job.
    //
    // Safe to push from here: an arrival that already happened opens Screen 5
    // over the top through _watchForArrival, which is the same order a ride
    // produces live, and a wake ladder outranks both by design.
    //
    // Gated on the host, not on the platform. The debug screen shares this
    // mixin, and pushing Screen 4 over it would cover the bench that forces the
    // ladder and the wind-down at the exact moment those benches need a ride to
    // be running. See [resumesTravelModeScreen].
    if (resumesTravelModeScreen) await showTravelMode();
  }

  /// One event from the other side of the isolate boundary, already parsed
  /// (lib/services/ride_service_client.dart). Only what a SCREEN owns lands
  /// here; the ladder, wind-down and tone events belong to [rideAlertsProvider]
  /// and never reach this method.
  void _onServiceEvent(ServiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case ServiceLogged(:final message):
        onOrchestrationLog(message);
      case WakeLadderChanged():
      case WindDownChanged():
      case ToneCommanded():
      case VibrateCommanded():
      case RideProgressed():
      case DestinationReached():
      case AlightingAt():
        // liveRideProvider owns progress and arrival; Screen 5 opens off that
        // provider (see _watchForArrival) rather than off this stream, so a
        // host that was not mounted when the event passed still catches up.
        break;
      case RideEndedByService():
        unawaited(onRideEndedByService());
      case ServiceFix(:final lat, :final lng, :final accuracyM):
        _lastServiceFix = (
          lat: lat,
          lng: lng,
          accuracyM: accuracyM,
          at: DateTime.now(),
        );
        // Keeps the chip live during the ride too. The origin cannot follow the
        // train because start() confirmed it as the rider's pick, and a fix
        // never moves a pick (see JourneyDraftNotifier.confirmOrigin).
        ref.read(nearestStationProvider.notifier).applyFix(lat, lng, accuracyM);
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();

    final whileInUse = await Permission.locationWhenInUse.request();
    if (whileInUse.isGranted) {
      await Permission.locationAlways.request();
    }

    await service.requestBatteryOptimizationExemption();
  }

  Future<void> start() async {
    final journey = ref.read(plannedJourneyProvider).journey;
    if (journey == null) return;

    // The rider pressed Start on THIS journey, so its origin is now their
    // choice however it got there. Done before the awaits below, so the plan
    // held here and the draft cannot disagree while permissions are answered.
    ref.read(journeyDraftProvider.notifier).confirmOrigin();

    await _requestPermissions();

    // Read BEFORE the service starts, so the reading belongs to the ride rather
    // than to whatever the battery had already lost to starting it.
    final startBattery = await _batteryPct();
    // AWAITED, not read. appSettingsProvider is an AsyncNotifier and no screen
    // here watches it, so a plain read returns AsyncLoading and valueOrNull is
    // null. That silently handed the service "no pulse" on every ride, which is
    // exactly what the device showed twice before this line was fixed: settings
    // that persist are not settings that arrive.
    final pulseSettings = await ref.read(appSettingsProvider.future);

    final started = await service.startRide(
      originStationId: journey.originStationId,
      destinationStationId: journey.destinationStationId,
      notificationText:
          '${stationName(journey.originStationId)} to '
          '${stationName(journey.destinationStationId)}',
      sarvamGreeting: sarvamGreeting,
      sarvamClips: sarvamClips,
      startedAt: DateTime.now(),
      startBatteryPct: startBattery,
      // Read at START, not only on change. pulseIntervalSeconds is the single
      // place crowd mode is folded in, so the service is handed one number and
      // never has to know the rule.
      pulseIntervalSeconds: pulseSettings.pulseIntervalSeconds,
      pulseVibrate: pulseSettings.vibrateWithPulse,
      shareAnonymousUsage: pulseSettings.shareAnonymousUsage,
      // From the same awaited read. The picker only ever offers a language
      // this device reported a voice for (TtsLanguageGateway), so what
      // arrives here is speakable.
      language: pulseSettings.language,
    );

    if (started) {
      // A new ride gets a new arrival screen.
      _arrivalShown = false;
      // Liveness comes from the store, never from an assumption here.
      await ref.read(liveRideProvider.notifier).refresh();
    }
  }

  Future<void> stop() async {
    await service.stopRide();
    await ref.read(liveRideProvider.notifier).refresh();
    await ref.read(rideAlertsProvider.notifier).standDown();
    await recordRide();
    await _defaultOriginToRideEnd();
  }

  /// The service ended the ride itself (wind-down auto-off or its End now
  /// button). Same after-ride path as a manual stop, minus stopping the
  /// service, which is already going down.
  Future<void> onRideEndedByService() async {
    // liveRideProvider refreshes itself from the same event, so this handler
    // only does the parts a screen owns: the history row and the turnaround.
    await ref.read(rideAlertsProvider.notifier).standDown();
    await recordRide();
    await _defaultOriginToRideEnd();
  }

  /// Battery percentage, or null if the platform will not say.
  ///
  /// Never allowed to throw or hang: this sits on the ride start and ride end
  /// paths, and a battery reading is a note on a journey, never a reason to
  /// lose one.
  Future<int?> _batteryPct() async {
    try {
      return await Battery().batteryLevel.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// Writes the finished ride into history, manual End and service auto-off
  /// both.
  ///
  /// EVERY FIELD COMES FROM THE STORE, not from widget state. These used to be
  /// three fields on the debug screen, which meant a journey that outlived its
  /// UI completed correctly and then never appeared in History. Swiping the app
  /// out of recents does exactly that: it does NOT stop the ride (the service
  /// restarts itself a second later, see ForegroundService.onTaskRemoved), so
  /// the ride survived and its record did not.
  ///
  /// Still best-effort in one narrower sense: a storage failure must never
  /// break the teardown path it rides on.
  Future<void> recordRide() async {
    final persisted = await service.readPersistedRide();
    final startedAt = persisted.startedAt;
    final originId = persisted.originId;
    final destinationId = persisted.destinationId;
    if (startedAt == null || originId == null || destinationId == null) return;

    // ALWAYS RE-PLANNED from the ids THE SERVICE WAS HANDED, never from the
    // live draft: the picker can replan mid-ride while the service keeps riding
    // the chain it was given.
    //
    // There used to be a `_startedJourney ??` fast path in front of this, kept
    // for a ride recorded in the same process. It was cleared three lines above
    // being read, so it was always null and every row has been replanned since
    // 29 Jul 2026. Removed 5 Aug: both routes plan from the same ids, so the
    // only thing it ever did was suggest a second source of truth for the
    // history row, which is exactly the shape of bug the store exists to end.
    final journey = _planStored(originId, destinationId);
    if (journey == null) {
      onOrchestrationLog('History skipped: cannot replan the ride');
      await service.clearRideRecordSeed();
      return;
    }

    try {
      await ref
          .read(appDatabaseProvider)
          .record(
            originId: originId,
            destinationId: destinationId,
            originName: stationName(originId),
            destinationName: stationName(destinationId),
            startedAt: startedAt,
            endedAt: DateTime.now(),
            reachedDestination: persisted.destinationReached,
            // The chain ends at the destination now; the overshoot pins live
            // outside it, so the journey length is simply the chain.
            stationCount: journey.chain.length,
            batteryStartPct: persisted.startBatteryPct,
            batteryEndPct: await _batteryPct(),
          );
    } catch (error) {
      onOrchestrationLog('History record failed: $error');
    }
    // Cleared whether or not the write landed, so a later teardown cannot
    // resurrect a journey that has already been dealt with.
    await service.clearRideRecordSeed();
    // Screen 1 is UNDERNEATH the ride, never disposed while it runs, so its
    // autoDispose query is still alive and still holding the answer it read
    // before the ride started. Without this the destination the rider just
    // rode to is missing from Recents until the app is killed, and the card
    // they would have tapped next is the one that is not there.
    ref.invalidate(recentDestinationsProvider);
  }

  /// Whether this destination is already one of the rider's saved routes.
  ///
  /// A failed read answers "not saved", which offers the card again rather
  /// than hiding it. Offering twice costs a tap; hiding it wrongly costs the
  /// rider the only moment the app ever asks.
  Future<bool> _isSaved(String destinationId) async {
    try {
      final saved = await ref.read(appDatabaseProvider).allSavedRoutes();
      return saved.any((route) => route.destinationStationId == destinationId);
    } catch (error) {
      onOrchestrationLog('Saved routes read failed: $error');
      return false;
    }
  }

  /// Keeps a destination under a name the rider chose, from Screen 5.
  ///
  /// The label is the identity: saving Home twice replaces it (see
  /// AppDatabase.saveRoute), so this is also how a rider whose Home moves
  /// corrects it. Failure is logged and swallowed: the ride is over, the
  /// screen has already confirmed, and there is nothing useful to ask a rider
  /// walking down a platform to do about a database write.
  Future<void> saveRoute({
    required String label,
    required String destinationId,
    required String destinationName,
  }) async {
    try {
      await ref
          .read(appDatabaseProvider)
          .saveRoute(
            label: label,
            destinationStationId: destinationId,
            destinationName: destinationName,
          );
      onOrchestrationLog('Saved route "$label" to $destinationName');
    } catch (error) {
      onOrchestrationLog('Saved route failed: $error');
      return;
    }
    if (!mounted) return;
    ref.invalidate(savedRoutesProvider);
  }

  /// The journey the service is riding, replanned from the stored ids.
  Journey? _planStored(String originId, String destinationId) {
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    if (repo == null) return null;
    try {
      return repo.planner.plan(
        originId: originId,
        destinationId: destinationId,
      );
    } catch (_) {
      return null;
    }
  }

  /// The next ride usually starts where the last one ended (ride out, turn
  /// around, ride back), so after a stop the origin defaults to the finished
  /// ride's destination and the old destination is cleared for a fresh pick.
  /// Before this, the origin kept the morning's value until the app was killed
  /// (both phones, 13 Jul ride test, at the Thane turnaround).
  ///
  /// ONLY for a ride that provably got there: the service records the
  /// destination arrival under [destinationReachedKey], and without it the
  /// default is a guess pointing anywhere. A bench Start/Stop near Shahad
  /// planted Kalyan as the origin this way (13 Jul). A ride stopped early falls
  /// back to the GPS fill instead, and either way the status chip is re-asked
  /// from a real fix, never assumed from the ride.
  ///
  /// The origin this plants is a DEFAULT, so the fix below can overrule it. A
  /// bench ride that "arrives" somewhere the rider never went used to survive
  /// as an origin until the app was killed (9 Aug, the Shahad false alarm).
  Future<void> _defaultOriginToRideEnd() async {
    final persisted = await service.readPersistedRide();
    if (!mounted) return;
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    final destination = persisted.destinationReached
        ? repo?.stationsById[persisted.destinationId]
        : null;

    ref
        .read(journeyDraftProvider.notifier)
        .resetAfterRide(originId: destination?.id);

    // Chip (and origin, when the ride ended somewhere unproven) from a real
    // fix. The service's last streamed fix is seconds old and free, so prefer
    // it; a cold acquisition indoors can time out, which left a blank origin
    // under a stale chip on the 13 Jul bench. Live GPS stays as the fallback.
    final fix = _lastServiceFix;
    final fresh =
        fix != null &&
        DateTime.now().difference(fix.at) < const Duration(minutes: 3);
    final nearest = ref.read(nearestStationProvider.notifier);
    if (fresh && nearest.applyFix(fix.lat, fix.lng, fix.accuracyM)) {
      return;
    }
    await nearest.locate();
  }

  String stationName(String stationId) =>
      ref
          .read(stationRepositoryProvider)
          .valueOrNull
          ?.stationsById[stationId]
          ?.name ??
      stationId;

  /// Screen 3, wired. The rider's route into a ride.
  ///
  /// NORMALLY SHOWS NOTHING. The probes run first and, when they all pass, the
  /// ride starts with no screen in between, because the fix is usually already
  /// held (Screen 1 acquires one on open) and the rest of the work is
  /// milliseconds. Pushing the flow unconditionally would flash a progress
  /// screen on every journey.
  ///
  /// The DEBUG screen's own Start button deliberately still calls [start]
  /// directly, so a bench is never gated on permissions or earphones.
  Future<void> prepareAndStart(String destinationId) async {
    // THE RIDE TO WHERE YOU ALREADY ARE. JourneyPlanner refuses it (it throws
    // on origin == destination), so plannedJourneyProvider holds an error, and
    // [start] then returns silently on a null journey: the rider tapped and
    // NOTHING happened, on every path into a ride. It is not a strange case
    // either. A saved Home is a station a rider stands at twice a day, and it
    // is right there in the picker on the resting list, which shows their own
    // line first.
    //
    // Answered here rather than in the picker because the picker is only one of
    // the three ways in; the saved and recent cards on Screen 1 are the others.
    if (ref.read(journeyDraftProvider).originId == destinationId) {
      onOrchestrationLog('Ride refused: already at $destinationId');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("You're already at ${stationName(destinationId)}."),
        ),
      );
      return;
    }

    final report = await const PreparingGate().check(ref);
    if (!mounted) return;

    if (report.clear) {
      await start();
      await showTravelMode();
      return;
    }

    final destination = stationName(destinationId);
    final proceed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            PreparingFlow(destinationName: destination, report: report),
      ),
    );
    if (!mounted || proceed != true) return;
    await start();
    await showTravelMode();
  }

  /// Screen 2. A pick sets the destination and starts the ride: origin is never
  /// picked, it is detected live from GPS.
  Future<void> pickDestination() async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => DestinationPickerScreen(
          onPicked: (station) {
            ref.read(journeyDraftProvider.notifier).setDestination(station.id);
            navigator.popUntil((route) => route.isFirst);
            unawaited(prepareAndStart(station.id));
          },
        ),
      ),
    );
  }

  /// Screen 4, for a ride that is actually running.
  ///
  /// Opened only when the service really started: liveRideProvider is the
  /// truth, never an assumption here, for the same reason [start] refuses to
  /// claim a ride the store does not report.
  ///
  /// It POPS ITSELF when the ride ends, whether the rider held End journey or
  /// the service wound down on its own. Without that, a rider whose ride
  /// auto-ended would be left looking at a countdown for a journey that had
  /// stopped.
  Future<void> showTravelMode() async {
    if (!mounted) return;
    if (ref.read(liveRideProvider).valueOrNull == null) return;
    final journey = ref.read(plannedJourneyProvider).journey;
    if (journey == null) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Consumer(
          builder: (context, ref, _) {
            final live = ref.watch(liveRideProvider).valueOrNull;
            if (live == null) {
              // The ride is over. Leave on the next frame: popping during a
              // build is not allowed.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (routeContext.mounted) Navigator.of(routeContext).maybePop();
              });
            }
            // WATCHED HERE, inside the pushed route's own Consumer, and that is
            // load bearing. Screen 4 lives in a MaterialPageRoute, so a
            // setState on the HOST does not rebuild it: punchlist item 2 was
            // exactly this bug, reported as "I can't toggle it". A provider the
            // route itself watches is the only thing that redraws this screen.
            final settings =
                ref.watch(appSettingsProvider).valueOrNull ??
                const AppSettings();
            return TravelModeScreen(
              journey: journey,
              wakeEnabled: wakeEnabled,
              // setState on the HOST is enough here ONLY because this route is
              // rebuilt by the Consumer around it; the flag is read on every
              // build. Punchlist item 2 was the same shape and did not have
              // that, which is why it looked dead.
              onWakeEnabled: (on) {
                setState(() => wakeEnabled = on);
                service.setWakeEnabled(on);
              },
              reachedIndex: live?.reachedIndex ?? -1,
              atStation: live?.atStation ?? false,
              wakeChoice: wakeChoice,
              crowdMode: settings.crowdMode,
              pulseIntervalSeconds: settings.pulseIntervalSeconds,
              // Writes through to settings AND pushes to the running ride, the
              // same pair Settings uses. Without the push the rider would keep
              // the old cadence until the ride ended, which is the "it didn't
              // take" that makes a control feel broken, and this one is tapped
              // in the exact moment it has to take: standing on a packed train.
              onCrowdMode: (on) async {
                await ref.read(appSettingsProvider.notifier).setCrowdMode(on);
                await pushPulseSettings();
              },
              onEndJourney: () async {
                await stop();
                if (routeContext.mounted) {
                  Navigator.of(routeContext).maybePop();
                }
              },
            );
          },
        ),
      ),
    );
  }

  /// Screen 5, Arrival, wired to the live ride. The last thing a ride shows.
  ///
  /// TRIGGERED BY ARRIVAL, NOT BY THE COUNTDOWN, which is what the screen's own
  /// doc asks for: WindDown only starts counting after two walking-speed fixes
  /// 150 m from where the train stopped, about six minutes after the doors
  /// opened on the 18 Jul Kalyan log. Waiting for the countdown would hide this
  /// screen for the whole walk down the platform, which is exactly when the
  /// rider is looking at their phone.
  ///
  /// END NOW MEANS TWO THINGS and this is the caller the screen's doc refers
  /// to. While a countdown runs it is WindDown's own End now; before one starts
  /// WindDown.endNow() early-returns, so it has to be the normal ride teardown
  /// or the button would do nothing at all.
  Future<void> showArrival() async {
    if (!mounted) return;
    final persisted = await service.readPersistedRide();
    if (!mounted) return;
    final journey = ref.read(plannedJourneyProvider).journey;
    final live = ref.read(liveRideProvider).valueOrNull;
    if (journey == null || live == null) return;

    // THE DESTINATION, not the chain index. An earlier draft read
    // journey.chain[reachedIndex] to name the platform the rider is standing
    // on, which was cleverness with a failure mode and no upside: the overshoot
    // pins live OUTSIDE the chain (see recordRide), so that index can never
    // name anything but the destination anyway, and it made this screen depend
    // on progress and arrival crossing the isolate boundary in order. The debug
    // bench, which fires an arrival without moving progress, showed "You've
    // arrived at Shahad" for a ride to Kalyan.
    //
    // AND THE OVERSHOOT, covered since 5 Aug 2026 by the service saying so
    // rather than by a guess here. A rider carried past their stop alights at
    // an overshoot pin, and this used to name the destination they never
    // reached. WindDown always knew (it moves its own exit anchor to the pin);
    // the fact simply did not travel. Now it does, as AlightingAt, and it is
    // watched rather than read once, because the pin is reached AFTER the
    // arrival and this screen is already open when it lands.
    final here = stationName(live.alightStationId ?? live.destinationId);

    final startedAt = persisted.startedAt;
    final minutes = startedAt == null
        ? null
        : DateTime.now().difference(startedAt).inMinutes;
    final summary = [
      if (minutes != null) '$minutes min',
      '${journey.chain.length} stations',
      '${stationName(live.originId)} → ${stationName(live.destinationId)}',
    ].join(' • ');

    // READ ONCE, BEFORE THE PUSH, and deliberately not watched. The question
    // is whether the rider had already saved this destination when they
    // arrived; watching it would take the card away in the same frame their
    // own tap answered it, which is the confirmation's job.
    final alreadySaved = await _isSaved(live.destinationId);
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Consumer(
          builder: (context, ref, _) {
            final alerts = ref.watch(rideAlertsProvider);
            final running = ref.watch(liveRideProvider).valueOrNull;
            final stillRunning = running != null;
            // Re-read from the WATCHED ride, so a pin reached while this screen
            // is already open renames the platform under the rider rather than
            // leaving the headline on the stop they were carried past.
            final alightingAt = running == null
                ? here
                : stationName(running.alightStationId ?? running.destinationId);
            if (!stillRunning) {
              // The ride is over, by auto-off or by End now. Leave on the next
              // frame: popping during a build is not allowed.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (routeContext.mounted) Navigator.of(routeContext).maybePop();
              });
            }
            final counting = alerts.windDownLive;
            return ArrivalScreen(
              destinationName: alightingAt,
              summaryLine: summary,
              autoEndAt: alerts.windDownEndsAt,
              window: alerts.windDownWindow,
              // NO POP HERE, deliberately. Ending the ride clears
              // liveRideProvider, and the watcher above pops this route on the
              // next frame. Doing both popped TWICE: on the device this screen
              // came down and took the screen underneath with it, landing on
              // Settings. It is invisible on the product path (Screen 5 over
              // Screen 4 lands on Screen 1 either way) which is exactly why it
              // would have survived.
              onEndNow: () async {
                if (counting) {
                  service.windDownEndNow();
                } else {
                  await stop();
                }
              },
              onExtend: counting ? service.windDownExtend : null,
              // Null hides the card, which is what a route already saved
              // should do. The screen asks for the label; the destination is
              // the one the service actually rode, never the draft, for the
              // same reason recordRide replans from the persisted ids.
              onSaveRoute: alreadySaved
                  ? null
                  : (label) => saveRoute(
                      label: label,
                      destinationId: live.destinationId,
                      destinationName: here,
                    ),
            );
          },
        ),
      ),
    );
  }

  /// Screen 7. Replaces the debug bottom sheet the debug screen used to carry.
  Future<void> showHistory() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const HistoryScreen()));
  }

  /// Hands the current pulse settings to the service, if a ride is running.
  ///
  /// Reads them back from the provider rather than taking an argument, so the
  /// three callers cannot each compute a slightly different answer about what
  /// crowd mode does to the interval. [AppSettings.pulseIntervalSeconds] is the
  /// single place that folds crowd mode in.
  Future<void> pushPulseSettings() async {
    if (!ref.read(isRideRunningProvider)) return;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    await service.setPulseInterval(
      seconds: settings.pulseIntervalSeconds,
      vibrate: settings.vibrateWithPulse,
    );
  }

  /// The readiness card's three rows, from what the platform actually says.
  ///
  /// [readiness] is null while the reads are still in flight, and every row is
  /// then [ReadinessState.checking]: this card may not guess. Guessing ok would
  /// tell a rider with revoked location that they are ready, and guessing
  /// unmet would send a rider who is fine hunting for a setting.
  ///
  /// PURE, and public for that reason: it is the one place that decides what
  /// green and amber MEAN, and that decision is worth a test which runs without
  /// a device. Every state below is reachable in a unit test; none of them is
  /// reachable in a widget test, because the platform reads behind them do not
  /// exist under the test binding.
  static List<ReadinessItem> readinessRows(
    TravelReadiness? readiness, {
    required VoidCallback onFixed,
    required PermissionsGateway gateway,
  }) {
    ReadinessState stateOf(bool? granted) => switch (granted) {
      null => ReadinessState.checking,
      true => ReadinessState.ok,
      false => ReadinessState.needsAttention,
    };

    // Re-read after the action, and understand what that does and does not
    // cover. `openAppSettings` returns when the system page LAUNCHES, so this
    // re-read sees the old value and is nearly pointless on that path; the
    // resume hook in `_onResumed` is what actually catches the rider coming
    // back. It earns its place on the battery path, where
    // `requestIgnoreBatteryOptimizations` shows an in-app system dialog and
    // returns the rider's actual answer. Kept on both so no Fix can ever be
    // the one that leaves the card stale.
    Future<void> fix(Future<void> Function() action) async {
      await action();
      onFixed();
    }

    return [
      ReadinessItem(
        label: 'Location, always',
        state: stateOf(readiness?.locationAlways),
        detail:
            'Travel Mode cannot follow your train without it. '
            'Choose "Allow all the time".',
        // The app's own settings page, NOT a permission request. On Android 11+
        // asking for background location shows no dialog with an "Allow all the
        // time" option at all, which is the trap onboarding already works
        // around; a request here would appear to do nothing.
        onFix: () => fix(gateway.openSettings),
      ),
      ReadinessItem(
        label: 'Notifications',
        state: stateOf(readiness?.notifications),
        detail:
            'The ride notification carries "I\'m awake" and "End now". '
            'Without it those live only on screen.',
        onFix: () => fix(gateway.openSettings),
      ),
      // ANDROID ONLY, and absent rather than grey on iOS: a row that can never
      // go green is worse than no row. Null here means the question does not
      // apply, which is not the same as an answer that has not arrived yet.
      if (readiness == null || readiness.batteryExempt != null)
        ReadinessItem(
          label: 'Battery use',
          state: stateOf(readiness?.batteryExempt),
          detail: 'Restricted. Android may stop the app mid journey.',
          // The system dialog first, because it is one tap where it appears.
          // MIUI and ColorOS, this project's named OEM risk, are exactly the
          // ROMs that refuse it, and the re-read after it returns is what
          // tells the rider whether it worked.
          onFix: () => fix(gateway.requestIgnoreBatteryOptimizations),
        ),
    ];
  }

  /// Screen 6, Settings.
  ///
  /// The settings themselves are REAL: every switch writes through to AppFlags
  /// and survives a restart. SO ARE THE READINESS ROWS since 12 Aug 2026; they
  /// were three hardcoded literals before that, on the card this app puts first
  /// because OEM battery kills are its own named top product risk.
  Future<void> openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            final settings =
                ref.watch(appSettingsProvider).valueOrNull ??
                const AppSettings();
            final languages =
                ref.watch(availableLanguagesProvider).valueOrNull ??
                {AppLanguage.english};
            final notifier = ref.read(appSettingsProvider.notifier);

            return SettingsScreen(
              settings: settings,
              availableLanguages: languages,
              versionLine: 'Commute Guardian 1.0.0 (1)',
              readiness: readinessRows(
                ref.watch(travelReadinessProvider).valueOrNull,
                // Re-read after the rider comes back from wherever the Fix
                // sent them. There is no lifecycle observer in this app, so
                // nothing else would ever notice that they fixed it, and a
                // card still showing amber after the rider did what it asked
                // is worse than the hardcoded row this replaced.
                onFixed: () => ref.invalidate(travelReadinessProvider),
                gateway: ref.read(permissionsGatewayProvider),
              ),
              onBack: () => Navigator.of(context).maybePop(),
              // Written to settings AND pushed to a running ride. Without the
              // push a rider who changes the interval mid-journey would keep
              // the old cadence until the ride ended, which is exactly the kind
              // of "it didn't take" that makes a setting feel broken.
              onPulseInterval: (minutes) async {
                await notifier.setPulseInterval(minutes);
                await pushPulseSettings();
              },
              onCrowdMode: (on) async {
                await notifier.setCrowdMode(on);
                await pushPulseSettings();
              },
              onVibrateWithPulse: (on) async {
                await notifier.setVibrateWithPulse(on);
                await pushPulseSettings();
              },
              onAnnounceEveryStation: notifier.setAnnounceEveryStation,
              onShareAnonymousUsage: notifier.setShareAnonymousUsage,
              onLanguage: notifier.setLanguage,
              onVersionLongPress: debugDoor,
            );
          },
        ),
      ),
    );
  }
}
