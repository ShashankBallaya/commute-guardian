import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/journey.dart';
import 'models/station.dart';
import 'screens/arrival_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_shell.dart';
import 'screens/ride_orchestration.dart';
import 'screens/preparing_screen.dart';
import 'screens/travel_mode_screen.dart';
import 'screens/wake_alert_screen.dart';
import 'services/crash_reporting.dart';
import 'services/ride_service_client.dart';
import 'services/wind_down.dart';
import 'state/journey_providers.dart';
import 'state/ride_providers.dart';
import 'state/settings_providers.dart';
import 'theme/app_theme.dart';
import 'theme/palette.dart';
import 'widgets/pressable.dart';
import 'widgets/primary_button.dart';
import 'widgets/status_chip.dart';

void main() {
  RideServiceClient.initCommunicationPort();

  // LIGHT STATUS BAR ICONS, stated once, because nothing else in this app ever
  // says it: there is no AppBar anywhere, and an AppBar is what normally tells
  // the platform what the bars should look like. Without this the icons follow
  // the PHONE's mode, so a light-mode Android rider got dark icons on a
  // near-black ground and lost the clock and the battery. Punchlist item 10,
  // 12 Aug 2026, the other half of the white launch window.
  //
  // `.light` means light CONTENT (Brightness.light icons), which is the
  // opposite of what the name suggests on first reading, so both bars are also
  // set explicitly rather than left to the preset.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Palette.ground,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // ProviderScope holds the UI isolate's providers. It is deliberately absent
  // from the service isolate (lib/foreground/geofence_task_handler.dart):
  // providers do not cross isolates, and the ride's truth lives over there.
  // See docs/design/riverpod-adoption.md.
  runApp(const ProviderScope(child: CommuteGuardianDebugApp()));

  // AFTER runApp, AND NOT AWAITED. THE ORDER OF THESE TWO LINES IS THE FIX FOR
  // A WHITE SCREEN THAT COST THE ENTIRE APP ON iOS (10 Aug 2026).
  //
  // Sentry used to wrap runApp through its own appRunner, which reads as the
  // safer arrangement and is not: `Sentry._init` awaits EVERY integration before
  // it calls appRunner, with no timeout, and one of them initialises the native
  // SDK over a method channel. On the first IPA ever built with a real DSN, one
  // of those integrations never returned, so runApp was never reached and the
  // iPhone showed a white screen forever. The same commit started normally on
  // Android, and a build with the DSN removed opened instantly, which is how the
  // culprit was identified rather than guessed.
  //
  // What this costs is written out in CrashReporting.startUiIsolate. The short
  // version: errors in the first few hundred milliseconds go unreported, and
  // that is the correct side to lose. Nothing that watches a ride may prevent
  // one, which is the same rule Aptabase's init and the analytics boot already
  // follow.
  unawaited(CrashReporting.startUiIsolate());
}

class CommuteGuardianDebugApp extends StatelessWidget {
  const CommuteGuardianDebugApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Commute Guardian',
      theme: commuteGuardianTheme(),
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

class _RideDebugScreenState extends ConsumerState<RideDebugScreen>
    with RideOrchestration {
  /// The raw event log. Scaffolding: it stays a widget field on purpose,
  /// because no product screen will have it and the debug screen dies with
  /// the Figma work.
  final List<String> _logs = [];

  /// Screen 4's crowd-mode control, for the PREVIEW only. The preview draws
  /// the screen with no ride behind it, so this is the local state a press has
  /// to move; a real ride reads the setting through the provider.
  bool _previewCrowdMode = false;

  /// Debug bench flag: Sarvam clip greets at Start (Android only). Handed to
  /// the service through the store at Start; default off keeps Start stock.
  bool _sarvamGreeting = false;

  /// Debug bench flag, clip slice 2: station announcements play as Sarvam
  /// clips from the pushed pack (Android only). Same lifecycle as the
  /// greeting flag: per-Start, default off.
  bool _sarvamClips = false;

  /// The two bench flags reach the service through [RideOrchestration.start],
  /// which asks for them rather than knowing about them. A product Start
  /// answers false to both and stays stock.
  @override
  bool get sarvamGreeting => _sarvamGreeting;
  @override
  bool get sarvamClips => _sarvamClips;

  /// The orchestration's running commentary, which only this screen has
  /// anywhere to put.
  @override
  void onOrchestrationLog(String message) {
    if (!mounted) return;
    setState(() => _logs.insert(0, message));
  }

  /// Whether the rider waved the "tap the chip to retry" tip away this
  /// session. The tip is contextual: it appears with the unavailable state,
  /// which is exactly when a new user needs to learn the chip is tappable,
  /// and leaves on its own the moment a fix lands.
  bool _chipTipDismissed = false;

  // Owned here rather than left to DropdownMenu's own internal controller, so
  // that filling the origin in from GPS can update the field's text without
  // rebuilding the menu. Rebuilding it would snap a menu the rider had already
  // opened shut under their thumb.
  final TextEditingController _originField = TextEditingController();
  final TextEditingController _destinationField = TextEditingController();

  @override
  void initState() {
    super.initState();
    initOrchestration();
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
    disposeOrchestration();
    _originField.dispose();
    _destinationField.dispose();
    // The history database is not closed here either: like the service client
    // it belongs to a provider, so it survives a screen going away.
    super.dispose();
  }

  void _testTts() => service.testTts();

  void _testWakeAlert() => service.testWakeAlert();

  void _testWindDown() => service.testWindDown();

  /// Pocket Pulse bench, section 7 of docs/design/pocket-pulse.md. Plain tap
  /// is the chime on its own; LONG PRESS fires it 150 ms into a spoken line,
  /// which is the 21 Jul collision that once stood the wake ladder down.
  void _testPulse() => service.testPulse();
  void _testPulseCollision() => service.testPulseCollision();

  void _wakeAck() => service.ackWakeFromButton();

  void _windDownEndNow() => service.windDownEndNow();

  void _windDownExtend() => service.windDownExtend();

  /// Opens the REAL home over the debug screen, shell and all, so what is
  /// judged on the device is the thing the entry gate now opens rather than a
  /// second copy of its wiring.
  Future<void> _previewHome() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const HomeShell()));
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
            // The PREVIEW's own state, deliberately local. This bench draws the
            // screen without a ride, so there is no live pulse for a real
            // toggle to reach; the control is here to be looked at and pressed.
            crowdMode: _previewCrowdMode,
            pulseIntervalSeconds: _previewCrowdMode ? 45 : 180,
            onCrowdMode: (on) => setLocal(() => _previewCrowdMode = on),
            onEndJourney: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }

  /// Screen 5, both states, as a preview.
  ///
  /// NOT WIRED, for the same reason Screen 3 is not: the wind-down path has a
  /// verification ride pending and the notification's End now / Extend buttons
  /// are the ride-proven controls. Wiring this replaces them, which is its own
  /// decision.
  ///
  /// The chooser is what makes the second state testable at all. It is the
  /// state a rider sees FIRST and for MINUTES, and it does not appear in any
  /// frame, so without an entry here nobody would ever look at it.
  Future<void> _previewScreen5() async {
    final counting = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Palette.surfaceSolid,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (isCounting, label) in const [
              (false, 'Arrived, waiting for you to leave'),
              (true, 'Counting down to auto end'),
            ])
              ListTile(
                key: Key('preview_screen5_$isCounting'),
                title: Text(label, style: const TextStyle(color: Palette.text)),
                onTap: () => Navigator.of(sheet).pop(isCounting),
              ),
          ],
        ),
      ),
    );
    if (!mounted || counting == null) return;

    final draft = ref.read(journeyDraftProvider);
    final repo = ref.read(stationRepositoryProvider).valueOrNull;
    final destination =
        repo?.stationsById[draft.destinationId]?.name ?? 'Kalyan';
    final origin = repo?.stationsById[draft.originId]?.name ?? 'Dadar';

    // Declared OUTSIDE the builder, or Extend would set a new deadline and the
    // very rebuild it triggers would throw it away.
    var endsAt = counting ? DateTime.now().add(WindDown.countdown) : null;
    var window = WindDown.countdown;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, setLocal) => ArrivalScreen(
            destinationName: destination,
            summaryLine: '52 min • 18 stations • $origin → $destination',
            autoEndAt: endsAt,
            window: window,
            onEndNow: () => Navigator.of(context).maybePop(),
            onExtend: counting
                ? () => setLocal(() {
                    endsAt = DateTime.now().add(WindDown.extension);
                    window = WindDown.extension;
                  })
                : null,
            onSaveRoute: (_) => Navigator.of(context).maybePop(),
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
                title: Text(label, style: const TextStyle(color: Palette.text)),
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
    final destination =
        repo?.stationsById[draft.destinationId]?.name ?? 'Kalyan';

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

  /// Proves this build's DSN reaches Sentry. Debug only, and it exists because
  /// crash reporting fails SILENTLY: a wrong DSN, a missing dart-define and a
  /// blocked network all look identical to an app that simply has not crashed.
  Future<void> _testCrashReporting() async {
    final result = await CrashReporting.sendTestEvent();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }

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
      // The keyboard belongs to the station search SHEET, not to this page:
      // nothing here is a text field the rider types into. Letting it resize
      // the body just squeezed a fixed-height column until it overflowed by
      // 271 px. It overlays now, and the sheet keeps managing its own inset.
      resizeToAvoidBottomInset: false,
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
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TestButton(
                        label: 'Pulse',
                        onPressed: isRunning ? _testPulse : null,
                        onLongPress: isRunning ? _testPulseCollision : null,
                      ),
                    ),
                  ],
                ),
              if (!isRunning)
                SizedBox(
                  height: 22,
                  child: Row(
                    children: [
                      // The previews SCROLL. Every new screen adds an icon here
                      // and the row overflowed twice while shaving the gaps
                      // between them; a seventh would have done it again.
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
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
                                  onPressed: showHistory,
                                ),
                              ),
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
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
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
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
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
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
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 22,
                                child: IconButton(
                                  key: const Key('arrival_preview_button'),
                                  padding: EdgeInsets.zero,
                                  iconSize: 18,
                                  tooltip: 'Preview Screen 5',
                                  icon: Icon(
                                    Icons.flag_outlined,
                                    color: Palette.textDim(0.6),
                                  ),
                                  onPressed: _previewScreen5,
                                ),
                              ),
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
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
                              // 8, not 14: the sixth preview icon (Screen 5) overflowed
                              // this row by 28 px on the 3T.
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 22,
                                child: IconButton(
                                  key: const Key('settings_preview_button'),
                                  padding: EdgeInsets.zero,
                                  iconSize: 18,
                                  tooltip: 'Preview Screen 6',
                                  icon: Icon(
                                    Icons.settings_outlined,
                                    color: Palette.textDim(0.6),
                                  ),
                                  onPressed: openSettings,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Sends one deliberate event to Sentry and says
                              // what happened. The row scrolls, which is why a
                              // ninth icon is allowed to exist.
                              SizedBox(
                                width: 22,
                                child: IconButton(
                                  key: const Key('sentry_test_button'),
                                  padding: EdgeInsets.zero,
                                  iconSize: 18,
                                  tooltip: 'Send a test event to Sentry',
                                  icon: Icon(
                                    Icons.bug_report_outlined,
                                    color: Palette.textDim(0.6),
                                  ),
                                  onPressed: _testCrashReporting,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
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
                onStart: start,
                onEnd: stop,
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
  const _TestButton({
    required this.label,
    required this.onPressed,
    this.buttonKey,
    this.onLongPress,
  });

  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  /// A second bench action hidden behind a long press, for the case where a
  /// button would otherwise need a twin. Today: the Pocket Pulse collision
  /// test, which is the same chime fired 150 ms into a spoken line.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return OutlinedButton(
      key: buttonKey,
      onPressed: onPressed,
      onLongPress: onLongPress,
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
          // The SECOND rippling TextButton, and the punchlist only knew about
          // the first. Same reason as the onboarding skip: Material's InkWell
          // reads as stock Android in a custom dark glass design, and this one
          // sits on Screen 1 under a banner that only appears when the rider
          // is already having trouble.
          //
          // 48 dp floor stated, because Pressable brings no minimum of its own
          // and TextButton did.
          Pressable(
            onTap: onDismiss,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 64),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Got it',
                style: TextStyle(fontSize: 14, color: Palette.text),
              ),
            ),
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
                // .en, not the ride's language: this is the debug screen, and
                // every word around it is English. A SpokenName interpolated
                // whole would print "Instance of 'SpokenName'", which the
                // analyzer is happy with and a reader is not.
                final walkTo = i.walkToStationName?.en;
                if (walkTo != null) {
                  return 'At $at walk across to $walkTo, then '
                      '${i.toLineShortName} towards '
                      '${i.towardsStationName.en}.';
                }
                if (i.isSameNamedService) {
                  return 'Change at $at for the train towards '
                      '${i.towardsStationName.en}.';
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
        // Bounded and scrollable rather than free-growing. A 28 station
        // cross-line chain ran to eight lines, which starved the Expanded
        // debug log below and overflowed the screen by 271 px with the
        // keyboard up. Scrolling keeps the whole chain readable, which the
        // bench does use, without letting it size the page.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 96),
          child: SingleChildScrollView(
            child: Text(
              stops.map((s) => s.name).join(' → '),
              style: TextStyle(fontSize: 12, color: Palette.textDim(0.5)),
            ),
          ),
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
      // TAP, and the same button Screen 3 uses. This was a slide until 11 Aug
      // 2026, on the reasoning that both ends of a ride should be deliberate
      // gestures and deliberately different ones. That reasoning does not
      // survive the product, and the arguments are written out in
      // [PrimaryButton]: the short version is that a partial drag which snaps
      // back leaves a rider believing the alarm is armed when no ride is
      // running, and this app cannot afford an input whose failure mode is "you
      // think you did it". The product path never had the slide, so this also
      // ends a split where the debug screen and Screen 3 started rides
      // differently and only the debug one carried the rationale.
      return PrimaryButton(
        label: 'Start the ride',
        enabled: canStart,
        onTap: onStart,
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
    // Starts the UI isolate's analytics once the rider's opt-out has been read
    // from the database. Watched here rather than called from main() because
    // main() runs before ProviderScope exists, and reading settings there would
    // mean opening the drift database a second time.
    //
    // Nothing depends on the result: analytics must never gate a screen.
    ref.watch(analyticsBootProvider);
    final seen = ref.watch(onboardingSeenProvider);
    return seen.when(
      // A blank frame for one database read, rather than flashing the wrong
      // screen and correcting itself.
      loading: () => const Scaffold(body: SizedBox.shrink()),
      // If the flag cannot be read, show the app rather than trapping the
      // rider in onboarding they may have already done.
      error: (_, _) => _home(context),
      data: (done) => done
          ? _home(context)
          : OnboardingScreen(
              onDone: () async {
                await ref.read(appDatabaseProvider).markOnboardingSeen();
                ref.invalidate(onboardingSeenProvider);
              },
            ),
    );
  }

  /// SCREEN 1 IS THE APP'S HOME, as of 4 Aug 2026, which is what the Phase 2
  /// exit criterion asks for: a rider who has never seen the debug screen can
  /// install, onboard, pick a destination, ride, be woken, arrive and end
  /// without it appearing once.
  ///
  /// The debug screen is still there and still runs every bench, one long press
  /// on Settings' version line away. Demoted, never deleted.
  Widget _home(BuildContext context) => HomeShell(
    onOpenDebug: () => Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const RideDebugScreen())),
  );
}
