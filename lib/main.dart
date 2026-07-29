import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models/journey.dart';
import 'models/station.dart';
import 'screens/destination_picker_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/preparing_flow.dart';
import 'screens/preparing_screen.dart';
import 'screens/travel_mode_screen.dart';
import 'screens/wake_alert_screen.dart';
import 'services/ride_service_client.dart';
import 'state/journey_providers.dart';
import 'state/ride_providers.dart';
import 'theme/palette.dart';
import 'widgets/slide_to_start.dart';
import 'widgets/status_chip.dart';

void main() {
  RideServiceClient.initCommunicationPort();
  // ProviderScope holds the UI isolate's providers. It is deliberately absent
  // from the service isolate (lib/foreground/geofence_task_handler.dart):
  // providers do not cross isolates, and the ride's truth lives over there.
  // See docs/design/riverpod-adoption.md.
  runApp(const ProviderScope(child: CommuteGuardianDebugApp()));
}

class CommuteGuardianDebugApp extends StatelessWidget {
  const CommuteGuardianDebugApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return MaterialApp(
      title: 'Commute Guardian (Phase 0 debug)',
      theme: base.copyWith(
        scaffoldBackgroundColor: Palette.ground,
        colorScheme: base.colorScheme.copyWith(
          surface: Palette.ground,
          primary: Palette.text,
          onSurface: Palette.text,
        ),
        textTheme: base.textTheme.apply(
          bodyColor: Palette.text,
          displayColor: Palette.text,
        ),
        // The pickers and the search sheet's field: dark wells recessed into
        // the glass surfaces, no hard borders.
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Palette.groundDeep,
          labelStyle: TextStyle(color: Palette.textDim(0.6)),
          hintStyle: TextStyle(color: Palette.textDim(0.4)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          // Opaque: a snackbar floats over whatever is on screen, and a
          // translucent fill would pick up the content behind it.
          backgroundColor: Palette.surfaceSolid,
          contentTextStyle: const TextStyle(color: Palette.text),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: const _EntryGate(),
    );
  }
}

/// Debug screen: pick a ride, start it, and watch events stream in. Wears the
/// approved Phase 2 design system (quiet status chip, glass cards, crimson
/// journey CTA, actions in the thumb zone), but it is still the debug tool:
/// the raw event log stays, which no product screen will have.
class RideDebugScreen extends ConsumerStatefulWidget {
  const RideDebugScreen({super.key});

  @override
  ConsumerState<RideDebugScreen> createState() => _RideDebugScreenState();
}

class _RideDebugScreenState extends ConsumerState<RideDebugScreen> {
  /// The raw event log. Scaffolding: it stays a widget field on purpose,
  /// because no product screen will have it and the debug screen dies with
  /// the Figma work.
  final List<String> _logs = [];

  /// Screen 4's wake control. Held here so it survives the screen being popped
  /// and re-pushed within a ride.
  ///
  /// NOTHING CONSUMES IT YET. The wake ladder still fires on its locked rules,
  /// and this must not quietly become a second way to change leadTimeS.
  WakeChoice _wakeChoice = WakeChoice.lastTwoStations;

  /// Debug bench flag: Sarvam clip greets at Start (Android only). Handed to
  /// the service through the store at Start; default off keeps Start stock.
  bool _sarvamGreeting = false;

  /// Debug bench flag, clip slice 2: station announcements play as Sarvam
  /// clips from the pushed pack (Android only). Same lifecycle as the
  /// greeting flag: per-Start, default off.
  bool _sarvamClips = false;

  /// The journey handed to the service at Start, as a FAST PATH only.
  /// [plannedJourneyProvider] cannot serve: the picker can replan it mid-ride
  /// while the service keeps riding the chain it was handed. This is the
  /// Journey/Ride distinction in CONTEXT.md made concrete, which is also why
  /// the field is named for the journey and not for the ride.
  ///
  /// NO LONGER LOAD-BEARING, as of 29 Jul 2026. The history row's real source
  /// is the shared store, and _recordRide replans from the ids the service was
  /// handed when this field is empty. That is what makes a journey survive the
  /// app being swiped out of recents with its record intact: the service
  /// restarts itself a second later, so the ride went on while its record used
  /// to die with the widget.
  Journey? _startedJourney;

  /// Whether the rider waved the "tap the chip to retry" tip away this
  /// session. The tip is contextual: it appears with the unavailable state,
  /// which is exactly when a new user needs to learn the chip is tappable,
  /// and leaves on its own the moment a fix lands.
  bool _chipTipDismissed = false;

  /// The freshest fix streamed up from the running service. At ride end this
  /// is seconds old and free, so it names the rider's position instantly; a
  /// cold GPS acquisition indoors can hang instead (13 Jul bench).
  ({double lat, double lng, double accuracyM, DateTime at})? _lastServiceFix;

  // Owned here rather than left to DropdownMenu's own internal controller, so
  // that filling the origin in from GPS can update the field's text without
  // rebuilding the menu. Rebuilding it would snap a menu the rider had already
  // opened shut under their thumb.
  final TextEditingController _originField = TextEditingController();
  final TextEditingController _destinationField = TextEditingController();

  /// The only door to the service isolate, owned by a provider so it outlives
  /// this screen. Nothing else in this file may touch FlutterForegroundTask;
  /// test/isolate_boundary_test.dart enforces it.
  RideServiceClient get _service => ref.read(rideServiceClientProvider);
  late final StreamSubscription<ServiceEvent> _serviceEvents;

  @override
  void initState() {
    super.initState();
    _serviceEvents = _service.events.listen(_onServiceEvent);
    // Forces the alerts notifier to exist before the first frame, so a ladder
    // event arriving between launch and the first build is not missed.
    ref.read(rideAlertsProvider);
    _openingSequence();
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
    // because the fill never overwrites and the restore always writes.
    unawaited(_restoreRunningRide());
    await ref.read(nearestStationProvider.notifier).locate();
  }

  /// The chip's tap: ask for a fresh fix. A single 8s attempt at launch is a
  /// coin flip indoors on an old phone (14 Jul bench, twice), so the miss must
  /// not be a final verdict. No-op mid-ride: the service stream owns the chip.
  void _retryLocate() {
    if (ref.read(isRideRunningProvider) ||
        ref.read(nearestStationProvider).state == GpsState.locating) {
      return;
    }
    unawaited(ref.read(nearestStationProvider.notifier).locate());
  }

  @override
  void dispose() {
    // The client itself is NOT disposed here: it belongs to a provider that
    // outlives this screen, which is what stops an activity recreation from
    // tearing the bridge down and putting it back up.
    unawaited(_serviceEvents.cancel());
    _originField.dispose();
    _destinationField.dispose();
    // The history database is not closed here either: like the service client
    // it belongs to a provider, so it survives a screen going away.
    super.dispose();
  }

  /// Rebuilds the pickers and route summary from the service store when the
  /// UI comes up with a ride already live. Android recreated the activity
  /// mid-ride on 15 Jul and the rebuilt screen showed a blank destination
  /// and no route while End journey was correctly offered; the service
  /// store has owned the truth about the running ride all along (it is what
  /// the service itself read at start), the UI just never asked it.
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
    setState(() {
      _logs.insert(0, 'Restored the running ride from the service store.');
    });
  }

  /// One event from the other side of the isolate boundary, already parsed
  /// (lib/services/ride_service_client.dart). Only what the SCREEN owns lands
  /// here; the ladder, wind-down and tone events belong to
  /// [rideAlertsProvider] and never reach this method.
  void _onServiceEvent(ServiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case ServiceLogged(:final message):
        setState(() => _logs.insert(0, message));
      case WakeLadderChanged():
      case WindDownChanged():
      case ToneCommanded():
      case RideProgressed():
        // liveRideProvider owns progress. The debug screen has no chain view.
        break;
      case RideEndedByService():
        unawaited(_onRideEndedByService());
      case ServiceFix(:final lat, :final lng, :final accuracyM):
        _lastServiceFix = (
          lat: lat,
          lng: lng,
          accuracyM: accuracyM,
          at: DateTime.now(),
        );
        // Keeps the chip live during the ride too; the origin cannot change
        // mid-ride because it is already set (see NearestStationNotifier).
        ref.read(nearestStationProvider.notifier).applyFix(lat, lng, accuracyM);
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();

    final whileInUse = await Permission.locationWhenInUse.request();
    if (whileInUse.isGranted) {
      await Permission.locationAlways.request();
    }

    await _service.requestBatteryOptimizationExemption();
  }

  Future<void> _start() async {
    final journey = ref.read(plannedJourneyProvider).journey;
    if (journey == null) return;

    await _requestPermissions();

    // Read BEFORE the service starts, so the reading belongs to the ride rather
    // than to whatever the battery had already lost to starting it.
    final startBattery = await _batteryPct();

    final started = await _service.startRide(
      originStationId: journey.originStationId,
      destinationStationId: journey.destinationStationId,
      notificationText:
          '${_name(journey.originStationId)} to '
          '${_name(journey.destinationStationId)}',
      sarvamGreeting: _sarvamGreeting,
      sarvamClips: _sarvamClips,
      startedAt: DateTime.now(),
      startBatteryPct: startBattery,
    );

    if (started) {
      // The store now owns the history row's seed (see startRide). This field
      // stays only as the fast path for a ride recorded in the same process.
      _startedJourney = journey;
      // Liveness comes from the store, never from an assumption here.
      await ref.read(liveRideProvider.notifier).refresh();
    }
  }

  /// Battery percentage, or null if the platform will not say.
  ///
  /// Never allowed to throw or hang: this sits on the ride start and ride end
  /// paths, and a battery reading is a note on a journey, never a reason to
  /// lose one.
  Future<int?> _batteryPct() async {
    try {
      return await Battery()
          .batteryLevel
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// Writes the finished ride into history, manual End and service auto-off
  /// both.
  ///
  /// EVERY FIELD COMES FROM THE STORE, not from widget state. These used to be
  /// three fields on this screen, which meant a journey that outlived its UI
  /// completed correctly and then never appeared in History. Swiping the app
  /// out of recents does exactly that: it does NOT stop the ride (the service
  /// restarts itself a second later, see ForegroundService.onTaskRemoved), so
  /// the ride survived and its record did not.
  ///
  /// Still best-effort in one narrower sense: a storage failure must never
  /// break the teardown path it rides on.
  Future<void> _recordRide() async {
    final persisted = await _service.readPersistedRide();
    final startedAt = persisted.startedAt;
    final originId = persisted.originId;
    final destinationId = persisted.destinationId;
    _startedJourney = null;
    if (startedAt == null || originId == null || destinationId == null) return;

    // Re-planned from the ids THE SERVICE WAS HANDED, never from the live
    // draft: the picker can replan mid-ride while the service keeps riding the
    // chain it was given. Same reason _startedJourney existed.
    final journey = _startedJourney ?? _planStored(originId, destinationId);
    if (journey == null) {
      setState(() => _logs.insert(0, 'History skipped: cannot replan the ride'));
      await _service.clearRideRecordSeed();
      return;
    }

    try {
      await ref.read(appDatabaseProvider).record(
        originId: originId,
        destinationId: destinationId,
        originName: _name(originId),
        destinationName: _name(destinationId),
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
      setState(() => _logs.insert(0, 'History record failed: $error'));
    }
    // Cleared whether or not the write landed, so a later teardown cannot
    // resurrect a journey that has already been dealt with.
    await _service.clearRideRecordSeed();
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

  Future<void> _stop() async {
    await _service.stopRide();
    await ref.read(liveRideProvider.notifier).refresh();
    await ref.read(rideAlertsProvider.notifier).standDown();
    await _recordRide();
    await _defaultOriginToRideEnd();
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
  /// planted Kalyan as the origin this way (13 Jul). A ride stopped early
  /// falls back to the GPS fill instead, and either way the status chip is
  /// re-asked from a real fix, never assumed from the ride.
  Future<void> _defaultOriginToRideEnd() async {
    final persisted = await _service.readPersistedRide();
    if (!mounted) return;
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    final destination = persisted.destinationReached
        ? repo?.stationsById[persisted.destinationId]
        : null;

    ref.read(journeyDraftProvider.notifier).resetAfterRide(
          originId: destination?.id,
        );

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

  void _testTts() => _service.testTts();

  void _testWakeAlert() => _service.testWakeAlert();

  void _testWindDown() => _service.testWindDown();

  void _wakeAck() => _service.ackWakeFromButton();

  void _windDownEndNow() => _service.windDownEndNow();

  void _windDownExtend() => _service.windDownExtend();

  /// The service ended the ride itself (wind-down auto-off or its End now
  /// button). Same after-ride path as a manual stop, minus stopping the
  /// service, which is already going down.
  /// Opens Screen 1 over the debug screen so it can be judged on a device.
  /// Starting from a card sets the destination and starts the ride: origin is
  /// never picked, it is detected live from GPS.
  Future<void> _previewHome() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          onStartTo: (destinationId) {
            ref.read(journeyDraftProvider.notifier).setDestination(destinationId);
            Navigator.of(context).pop();
            unawaited(_prepareAndStart(destinationId));
          },
          onNew: _pickDestination,
        ),
      ),
    );
  }

  /// Screen 2. A pick sets the destination and starts the ride: origin is
  /// never picked, it is detected live from GPS.
  Future<void> _pickDestination() async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => DestinationPickerScreen(
          onPicked: (station) {
            ref.read(journeyDraftProvider.notifier).setDestination(station.id);
            navigator.popUntil((route) => route.isFirst);
            unawaited(_prepareAndStart(station.id));
          },
        ),
      ),
    );
  }

  /// Screen 3, wired. The rider's route into a ride.
  ///
  /// NORMALLY SHOWS NOTHING. The probes run first and, when they all pass, the
  /// ride starts with no screen in between, because the fix is usually already
  /// held (Screen 1 acquires one on open) and the rest of the work is
  /// milliseconds. Pushing the flow unconditionally would flash a progress
  /// screen on every journey.
  ///
  /// The DEBUG screen's own Start button deliberately still calls [_start]
  /// directly, so a bench is never gated on permissions or earphones.
  Future<void> _prepareAndStart(String destinationId) async {
    final report = await const PreparingGate().check(ref);
    if (!mounted) return;

    if (report.clear) {
      await _start();
      await _showTravelMode();
      return;
    }

    final destination = _name(destinationId);
    final proceed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PreparingFlow(
          destinationName: destination,
          report: report,
        ),
      ),
    );
    if (!mounted || proceed != true) return;
    await _start();
    await _showTravelMode();
  }

  /// Screen 4, for a ride that is actually running.
  ///
  /// Opened only when the service really started: liveRideProvider is the
  /// truth, never an assumption here, for the same reason _start refuses to
  /// claim a ride the store does not report.
  ///
  /// It POPS ITSELF when the ride ends, whether the rider held End journey or
  /// the service wound down on its own. Without that, a rider whose ride
  /// auto-ended would be left looking at a countdown for a journey that had
  /// stopped, which is the exact failure the liveRideProvider subscription was
  /// added to prevent on the debug screen.
  Future<void> _showTravelMode() async {
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
            return TravelModeScreen(
              journey: journey,
              reachedIndex: live?.reachedIndex ?? -1,
              wakeChoice: _wakeChoice,
              onWakeChoiceChanged: (next) => setState(() => _wakeChoice = next),
              onEndJourney: () async {
                await _stop();
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

  /// Screen 4, as a preview. Uses the real planner and a mid-chain position, so
  /// what is judged on the device is the real chain, not a mock.
  Future<void> _previewTravelMode() async {
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    if (repo == null) return;
    final Journey journey;
    try {
      journey = repo.planner.plan(originId: 'thane', destinationId: 'kalyan');
    } catch (_) {
      return;
    }
    if (!mounted) return;

    var choice = WakeChoice.lastTwoStations;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, setLocal) => TravelModeScreen(
            journey: journey,
            reachedIndex: 2,
            wakeChoice: choice,
            onWakeChoiceChanged: (next) => setLocal(() => choice = next),
            onEndJourney: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }

  /// The wake alert, as a preview.
  ///
  /// NOT WIRED. The live alert path is the ride-proven one on this screen (the
  /// "I'm awake" button beside Announce) and it is the single most
  /// safety-critical control in the app, so replacing it is its own decision.
  Future<void> _previewWakeAlert() async {
    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => WakeAlertScreen(
          destinationName:
              repo?.stationsById[draft.destinationId]?.name ?? 'Kalyan',
          lastPassedLine: 'Thakurli passed 19:49',
          onAcknowledge: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Picks which Screen 3 state to preview.
  Future<void> _previewScreen3() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Palette.surfaceSolid,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, label) in const [
              'A  Getting ready',
              'B  Cannot find you',
              'C  Background location',
              'D  Before you doze off',
            ].indexed)
              ListTile(
                key: Key('preview_screen3_$index'),
                title: Text(
                  label,
                  style: const TextStyle(color: Palette.text),
                ),
                onTap: () => Navigator.of(sheet).pop(index),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 0:
        await _previewPreparing();
      case 1:
        await _previewCannotLocate();
      case 2:
        await _previewBackgroundLocation();
      case 3:
        await _previewPreflight();
    }
  }

  /// Screen 3 state D, as a preview only.
  Future<void> _previewPreflight() async {
    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    final destination = repo?.stationsById[draft.destinationId]?.name ?? 'Kalyan';

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => PreflightScreen(
          originName: repo?.stationsById[draft.originId]?.name ?? 'Shahad',
          destinationName: destination,
          steps: [
            const PrepStep(
              label: "Your earphones aren't connected",
              detail: 'The alarm will play out loud',
              status: PrepStatus.active,
            ),
            const PrepStep(
              label: 'Volume is low',
              detail: 'Turn it up so you hear us over the train',
              status: PrepStatus.active,
            ),
            PrepStep(
              label: 'Watching for $destination',
              status: PrepStatus.done,
            ),
          ],
          onStart: () => Navigator.of(context).maybePop(),
          onRecheck: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Screen 3 state A, as a preview only.
  ///
  /// The real trigger is a pick made while no fix is held, which is rare
  /// because Screen 1 acquires one on open. Wiring it into _start() is a change
  /// to the safety-critical path and is not made here.
  Future<void> _previewPreparing() async {
    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    String nameOf(String? id, String fallback) =>
        repo?.stationsById[id]?.name ?? fallback;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => PreparingScreen(
          originName: nameOf(draft.originId, 'Shahad'),
          destinationName: nameOf(draft.destinationId, 'Kalyan'),
          steps: const [
            PrepStep(
              label: 'Finding you',
              detail: 'This can take a few seconds indoors',
              status: PrepStatus.active,
            ),
            PrepStep(
              label: 'Watching for your stop',
              status: PrepStatus.pending,
            ),
            PrepStep(
              label: 'Direction',
              detail: 'Confirmed once the train moves',
              status: PrepStatus.pending,
            ),
          ],
          onCancel: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Screen 3 state B, as a preview only.
  ///
  /// "Set my station" is wired to a callback that does nothing yet: a manual
  /// origin picker does not exist, origin is only ever detected.
  Future<void> _previewCannotLocate() async {
    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    String nameOf(String? id, String fallback) =>
        repo?.stationsById[id]?.name ?? fallback;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => CannotLocateScreen(
          originName: nameOf(draft.originId, 'Shahad'),
          destinationName: nameOf(draft.destinationId, 'Kalyan'),
          onRetry: () => Navigator.of(context).maybePop(),
          onSetStation: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Screen 3 state C, as a preview only.
  ///
  /// "Open settings" is wired to a pop here rather than to
  /// permission_handler's openAppSettings, so a preview cannot send anyone
  /// into system settings by accident.
  Future<void> _previewBackgroundLocation() async {
    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    String nameOf(String? id, String fallback) =>
        repo?.stationsById[id]?.name ?? fallback;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => BackgroundLocationScreen(
          originName: nameOf(draft.originId, 'Shahad'),
          destinationName: nameOf(draft.destinationId, 'Kalyan'),
          onOpenSettings: () => Navigator.of(context).maybePop(),
          onStartAnyway: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Screen 7. Replaces the debug bottom sheet this screen used to carry.
  Future<void> _showHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
  }

  Future<void> _onRideEndedByService() async {
    // liveRideProvider refreshes itself from the same event, so this handler
    // only does the parts the screen owns: the history row and the turnaround.
    await ref.read(rideAlertsProvider.notifier).standDown();
    await _recordRide();
    await _defaultOriginToRideEnd();
  }

  String _name(String stationId) =>
      ref.read(stationRepositoryProvider).valueOrNull?.stationsById[stationId]
          ?.name ??
      stationId;

  void _holdToEndHint() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Hold to end the journey.')));
  }

  /// Keeps the two text fields showing whatever the draft says.
  ///
  /// The controllers stay widget-owned (they are controllers, not state), so
  /// this is the seam between them and the provider. It fires for every route
  /// into the draft: the rider picking, the GPS fill, the mid-ride restore and
  /// the post-ride turnaround, which is why none of those touch .text any
  /// more.
  void _syncFieldsToDraft(JourneyDraft? previous, JourneyDraft next) {
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    String nameOf(String? id) =>
        id == null ? '' : repo?.stationsById[id]?.name ?? '';
    if (previous?.originId != next.originId) {
      _originField.text = nameOf(next.originId);
    }
    if (previous?.destinationId != next.destinationId) {
      _destinationField.text = nameOf(next.destinationId);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<JourneyDraft>(journeyDraftProvider, _syncFieldsToDraft);

    final stations = ref.watch(stationsAlphabeticalProvider);
    final nearest = ref.watch(nearestStationProvider);
    final planned = ref.watch(plannedJourneyProvider);
    final draft = ref.read(journeyDraftProvider.notifier);
    // Liveness and alerts come from the store and the event stream, never from
    // this widget's memory, which is what makes recreation a non-event.
    final isRunning = ref.watch(isRideRunningProvider);
    final alerts = ref.watch(rideAlertsProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatusChip(
                state: nearest.state,
                stationName: nearest.stationName,
                onTap: _retryLocate,
              ),
              if (nearest.state == GpsState.unavailable &&
                  !isRunning &&
                  !_chipTipDismissed) ...[
                const SizedBox(height: 12),
                _ChipTipBanner(
                  onDismiss: () => setState(() => _chipTipDismissed = true),
                ),
              ],
              const SizedBox(height: 20),
              Container(
                decoration: Palette.glassCard(radius: 24),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StationPicker(
                      label: 'Origin',
                      stations: stations,
                      controller: _originField,
                      // Changing the ride mid-ride would leave the running service on
                      // the old one, which is a lie the log would not show.
                      enabled: !isRunning,
                      onChanged: draft.setOrigin,
                    ),
                    const SizedBox(height: 12),
                    _StationPicker(
                      label: 'Destination',
                      stations: stations,
                      controller: _destinationField,
                      enabled: !isRunning,
                      onChanged: draft.setDestination,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _JourneySummary(journey: planned.journey, error: planned.error),
              const SizedBox(height: 12),
              Expanded(child: _DebugLog(logs: _logs)),
              const SizedBox(height: 12),
              if (alerts.wakeLadderLive)
                // The manual dismiss, and the guaranteed ack fallback when
                // the earphone tap does not route to us. White fill: loud
                // enough to find half-asleep, and crimson stays reserved for
                // starting or ending a journey.
                //
                // Announce rides alongside it because this row used to REPLACE
                // the debug triggers outright, which made the one test that
                // discriminates the 22 Jul iPhone failure impossible to run:
                // firing a station announcement while a ladder climbs. Every
                // iPhone ladder that died that day went live within seconds of
                // an announcement, and the survivor did not, so being able to
                // stage that collision by hand is worth a debug button.
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        key: const Key('im_awake'),
                        onPressed: _wakeAck,
                        style: _urgentButtonStyle,
                        child: const Text(
                          "I'm awake",
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Announce',
                        onPressed: isRunning ? _testTts : null,
                        buttonKey: const Key('announce_during_ladder'),
                      ),
                    ),
                  ],
                )
              else if (alerts.windDownLive)
                // Mirrors the notification's wind-down actions for when the
                // phone is already in hand. White like the ack button;
                // crimson stays reserved for starting or ending a journey.
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        key: const Key('wind_down_end_now'),
                        onPressed: _windDownEndNow,
                        style: _urgentButtonStyle,
                        child: const Text(
                          'End now',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Extend 10 min',
                        onPressed: _windDownExtend,
                        buttonKey: const Key('wind_down_extend'),
                      ),
                    ),
                  ],
                )
              else
                // The three debug triggers, one per feature. "Test" dropped
                // from the labels to fit three abreast without growing the
                // column (the tall debug log lives in the Expanded above).
                Row(
                  children: [
                    Expanded(
                      child: _TestButton(
                        label: 'Announce',
                        onPressed: isRunning ? _testTts : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Wake alert',
                        onPressed: isRunning ? _testWakeAlert : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Wind-down',
                        onPressed: isRunning ? _testWindDown : null,
                      ),
                    ),
                  ],
                ),
              if (!isRunning)
                SizedBox(
                  height: 22,
                  child: Row(
                    children: [
                      // History icon per the design system: the plain
                      // clock-with-counterclockwise-arrow, never a stopwatch.
                      SizedBox(
                        width: 22,
                        child: IconButton(
                          key: const Key('history_button'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: 'Journey history',
                          icon: Icon(
                            Icons.history,
                            color: Palette.textDim(0.6),
                          ),
                          onPressed: _showHistory,
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Preview of the real Screen 1 while it is being built.
                      // The debug screen stays the app's home until Screen 1
                      // is approved on a device, so nothing half-finished can
                      // block a bench or a ride.
                      SizedBox(
                        width: 22,
                        child: IconButton(
                          key: const Key('home_preview_button'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: 'Preview Screen 1',
                          icon: Icon(
                            Icons.home_outlined,
                            color: Palette.textDim(0.6),
                          ),
                          onPressed: _previewHome,
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Preview of Screen 3 state A. Deliberately NOT wired
                      // into the start path: that path is safety-critical and
                      // has a verification ride pending, and on a normal ride
                      // this screen does not appear at all (the fix is already
                      // held by the time a destination is picked).
                      // ONE entry for all four Screen 3 states. Three separate
                      // icons filled this row and left no space for D; a
                      // chooser scales and keeps the row readable.
                      SizedBox(
                        width: 22,
                        child: IconButton(
                          key: const Key('preparing_preview_button'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: 'Preview Screen 3',
                          icon: Icon(
                            Icons.hourglass_empty,
                            color: Palette.textDim(0.6),
                          ),
                          onPressed: _previewScreen3,
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 22,
                        child: IconButton(
                          key: const Key('travel_mode_preview_button'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: 'Preview Screen 4',
                          icon: Icon(
                            Icons.train_outlined,
                            color: Palette.textDim(0.6),
                          ),
                          onPressed: _previewTravelMode,
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 22,
                        child: IconButton(
                          key: const Key('wake_alert_preview_button'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: 'Preview the wake alert',
                          icon: Icon(
                            Icons.notifications_active_outlined,
                            color: Palette.textDim(0.6),
                          ),
                          onPressed: _previewWakeAlert,
                        ),
                      ),
                      const Spacer(),
                      // Debug bench flag (Android only): Sarvam clip greets
                      // at Start, TTS still speaks the route line. Applied at
                      // the next Start; off keeps the Start path stock.
                      // Scaled down because a stock Switch carries a 48px tap
                      // target that does not fit this column.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Sarvam greeting',
                              style: TextStyle(color: Palette.textDim(0.6)),
                            ),
                            Switch(
                              key: const Key('sarvam_greeting_switch'),
                              value: _sarvamGreeting,
                              activeThumbColor: Palette.dotGreen,
                              onChanged: (value) =>
                                  setState(() => _sarvamGreeting = value),
                            ),
                            Text(
                              'Sarvam clips',
                              style: TextStyle(color: Palette.textDim(0.6)),
                            ),
                            Switch(
                              key: const Key('sarvam_clips_switch'),
                              value: _sarvamClips,
                              activeThumbColor: Palette.dotGreen,
                              onChanged: (value) =>
                                  setState(() => _sarvamClips = value),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              _JourneyCta(
                isRunning: isRunning,
                canStart: planned.journey != null,
                onStart: _start,
                onEnd: _stop,
                onEndTap: _holdToEndHint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet debug-only action. Outlined, dim, never competes with the journey
/// CTA; disabled when no ride (and so no service isolate) is running.
/// The white "act on this now" fill, shared by the wake ack and the
/// wind-down End now. Loud enough to find half-asleep, and crimson stays
/// reserved for starting or ending a journey (see the palette rule in
/// design-system decisions). Shared so the two cannot drift apart.
ButtonStyle get _urgentButtonStyle => ElevatedButton.styleFrom(
      backgroundColor: Palette.text,
      foregroundColor: Palette.ground,
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
    );

class _TestButton extends StatelessWidget {
  const _TestButton({required this.label, required this.onPressed, this.buttonKey});

  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return OutlinedButton(
      key: buttonKey,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.textDim(0.75),
        disabledForegroundColor: Palette.textDim(0.25),
        side: BorderSide(
          color: enabled ? Palette.textDim(0.3) : Palette.textDim(0.12),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Text(label),
    );
  }
}

/// The quiet status chip: glass surface, never loud, the dot alone carries
/// the GPS state (green = fixed, amber = acquiring, dim = unavailable).
/// Contextual tip that appears WITH the unavailable state: it teaches the
/// chip's tap exactly when a new user needs it, and leaves on its own the
/// moment a fix lands. Quiet like everything that is not the journey CTA.
class _ChipTipBanner extends StatelessWidget {
  const _ChipTipBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "Couldn't find your location. Tap the chip above to try again, "
              'or pick your origin by hand.',
              style: TextStyle(fontSize: 13, color: Palette.textDim(0.8)),
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(foregroundColor: Palette.text),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// One station picker. 127 stations is too many for an anchored dropdown on a
/// slow phone (13 Jul bench, 3T: the tap raised the keyboard but the menu
/// never showed, and the keyboard overflowed the screen by 84px), so the tap
/// opens a bottom sheet instead: a search field over a lazy list, and the
/// keyboard never appears on this screen at all.
class _StationPicker extends StatelessWidget {
  const _StationPicker({
    required this.label,
    required this.stations,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final List<Station> stations;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  Future<void> _openSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<Station>(
      context: context,
      isScrollControlled: true,
      // Opaque: the sheet is drawn over the screen behind it.
      backgroundColor: Palette.surfaceSolid,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          _StationSearchSheet(label: label, stations: stations),
    );
    if (picked != null) {
      controller.text = picked.name;
      onChanged(picked.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled && stations.isNotEmpty,
      readOnly: true,
      showCursor: false,
      style: const TextStyle(color: Palette.text),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: Icon(Icons.arrow_drop_down, color: Palette.textDim(0.6)),
      ),
      onTap: () => _openSheet(context),
    );
  }
}

/// The picker's bottom sheet: search field on top, matching stations below.
/// The list is built lazily, so only the visible rows exist; this is what
/// makes 127 stations instant where the dropdown was not.
class _StationSearchSheet extends StatefulWidget {
  const _StationSearchSheet({required this.label, required this.stations});

  final String label;
  final List<Station> stations;

  @override
  State<_StationSearchSheet> createState() => _StationSearchSheetState();
}

class _StationSearchSheetState extends State<_StationSearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final matches = [
      for (final station in widget.stations)
        if (station.matches(_query)) station,
    ];

    // Tall enough to feel like a place to search, short enough that the sheet
    // still reads as a sheet. The keyboard inset keeps the field above it.
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Palette.textDim(0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Which end of the journey this sheet is setting. The field
                  // behind it says so too, but the sheet covers it, and the
                  // hint text vanishes the moment you type. So it lives here,
                  // where it survives both.
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: Palette.textDim(0.4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    autofocus: true,
                    style: const TextStyle(color: Palette.text),
                    decoration: InputDecoration(
                      hintText: 'Search stations',
                      prefixIcon: Icon(
                        Icons.search,
                        color: Palette.textDim(0.5),
                      ),
                    ),
                    onChanged: (text) => setState(() => _query = text),
                  ),
                ],
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        'No stations match.',
                        style: TextStyle(color: Palette.textDim(0.5)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final station = matches[index];
                        return ListTile(
                          title: Text(
                            station.name,
                            style: const TextStyle(color: Palette.text),
                          ),
                          trailing: Text(
                            station.code,
                            style: TextStyle(
                              fontSize: 11,
                              color: Palette.textDim(0.5),
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(station),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the picked ride actually is: the stations it will pass, and any train
/// change it needs. Shown before Start so a wrong pick is obvious on the
/// platform, not thirty minutes into the wrong train. Info rows are the
/// quietest element on screen: caption text, bullet separators, no card.
class _JourneySummary extends StatelessWidget {
  const _JourneySummary({required this.journey, required this.error});

  final Journey? journey;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Text(
        error!,
        style: const TextStyle(fontSize: 13, color: Palette.dotAmber),
      );
    }
    if (journey == null) {
      return Text(
        'Pick an origin and a destination.',
        style: TextStyle(fontSize: 13, color: Palette.textDim(0.5)),
      );
    }

    final ride = journey!;
    // The overshoot pins are a safety net, not part of the trip. They are no
    // longer chain members, so the chain is already exactly the trip.
    final stops = ride.chain;
    final nameOf = {for (final s in ride.chain) s.id: s.name};
    final changes = ride.interchanges.isEmpty
        ? 'No change of train.'
        : ride.interchanges
              .map((i) {
                final at = nameOf[i.stationId] ?? i.stationId;
                if (i.walkToStationName != null) {
                  return 'At $at walk across to ${i.walkToStationName}, then '
                      '${i.toLineShortName} towards ${i.towardsStationName}.';
                }
                if (i.isSameNamedService) {
                  return 'Change at $at for the train towards '
                      '${i.towardsStationName}.';
                }
                return 'Change at $at onto ${i.toLineShortName}'
                    '${i.platform == null ? '' : ' (platform ${i.platform})'}.';
              })
              .join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${stops.length} stations • $changes',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Palette.textDim(0.85),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          stops.map((s) => s.name).join(' → '),
          style: TextStyle(fontSize: 12, color: Palette.textDim(0.5)),
        ),
      ],
    );
  }
}

/// The raw event stream. Debug-only affordance: kept readable but visually
/// quiet, so the journey CTA stays the loudest element on screen.
class _DebugLog extends StatelessWidget {
  const _DebugLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Palette.textDim(0.1)),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // When the rest of the screen (banner up, tall route summary) squeezes
      // this box below the title's own height, the title goes before the box
      // overflows: the stream is the point, the label is not.
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (constraints.maxHeight >= 48) ...[
              Text(
                'Debug log',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: Palette.textDim(0.4),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Expanded(
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        'Events will stream here once a journey starts.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Palette.textDim(0.35),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: logs.length,
                      itemBuilder: (context, index) => Text(
                        logs[index],
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Palette.textDim(0.55),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one crimson element on screen (locked rule: crimson fill only ever
/// starts or ends a journey). Idle it reads Start journey; while a ride runs
/// it becomes End journey with hold-to-confirm, so a pocketed thumb cannot
/// kill Travel Mode mid-ride.
class _JourneyCta extends StatelessWidget {
  const _JourneyCta({
    required this.isRunning,
    required this.canStart,
    required this.onStart,
    required this.onEnd,
    required this.onEndTap,
  });

  final bool isRunning;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );

    if (!isRunning) {
      // Slide, not tap. Both ends of a ride are deliberate gestures now, and
      // deliberately different ones: slide to begin, hold to stop, so a
      // half-asleep rider cannot do one while meaning the other.
      return SlideToStart(
        label: 'Slide to start',
        enabled: canStart,
        onStart: onStart,
      );
    }

    return ElevatedButton(
      onPressed: onEndTap,
      onLongPress: onEnd,
      style: ElevatedButton.styleFrom(
        backgroundColor: Palette.crimson,
        foregroundColor: Palette.text,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: shape,
        elevation: 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'End journey',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          Text(
            'hold to confirm',
            style: TextStyle(fontSize: 12, color: Palette.textDim(0.7)),
          ),
        ],
      ),
    );
  }
}

/// Decides which screen the app opens on.
///
/// Onboarding is not a nicety: without background location this app stops
/// watching the moment the screen goes off, and Android will not grant that
/// from a dialog. So a rider who has not been walked through it gets walked
/// through it, once.
///
/// The flag lives in the app database, which means A REINSTALL SHOWS
/// ONBOARDING AGAIN. That is correct rather than annoying: a reinstall also
/// wipes the permission grants onboarding exists to explain (observed on the
/// 3T, 16 Jul).
class _EntryGate extends ConsumerWidget {
  const _EntryGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seen = ref.watch(onboardingSeenProvider);
    return seen.when(
      // A blank frame for one database read, rather than flashing the wrong
      // screen and correcting itself.
      loading: () => const Scaffold(body: SizedBox.shrink()),
      // If the flag cannot be read, show the app rather than trapping the
      // rider in onboarding they may have already done.
      error: (_, _) => const RideDebugScreen(),
      data: (done) => done
          ? const RideDebugScreen()
          : OnboardingScreen(
              onDone: () async {
                await ref.read(appDatabaseProvider).markOnboardingSeen();
                ref.invalidate(onboardingSeenProvider);
              },
            ),
    );
  }
}
