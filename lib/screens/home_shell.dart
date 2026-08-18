import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/journey_providers.dart';
import '../state/ride_providers.dart';
import 'home_screen.dart';
import 'ride_orchestration.dart';

/// The app's home, and the thing the entry gate points at.
///
/// Screen 1 is a pure widget: it takes four callbacks and knows nothing about
/// the service isolate. This shell is what stands behind those callbacks, and
/// it is deliberately almost empty, because everything it does comes from
/// [RideOrchestration], which the debug screen shares. Two hosts, one ride
/// path: a bench and a rider cannot drift apart, which is the whole reason the
/// orchestration was hoisted out of the debug screen on 4 Aug 2026 rather than
/// copied.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.onOpenDebug});

  /// The dev door, handed down from the entry gate and hidden under a long
  /// press on Settings' version line. Null when there is nothing behind it,
  /// which is the case whenever the debug screen opened this shell itself.
  final VoidCallback? onOpenDebug;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with RideOrchestration {
  @override
  VoidCallback? get debugDoor => widget.onOpenDebug;

  /// The product host, so a rider who comes back to a running ride lands on it.
  @override
  bool get resumesTravelModeScreen => true;

  @override
  void initState() {
    super.initState();
    initOrchestration();
  }

  @override
  void dispose() {
    disposeOrchestration();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeScreen(
      onStartTo: (destinationId) {
        // The draft is set before the gate runs, so Screen 3 and the service
        // both read the same destination the rider tapped.
        ref.read(journeyDraftProvider.notifier).setDestination(destinationId);
        unawaited(prepareAndStart(destinationId));
      },
      onNew: pickDestination,
      // The ride the OS killed. Read at the moment of the tap rather than
      // captured in the build, so a rider who presses this while the store is
      // still being re-read cannot resume a ride that has since been declined
      // or has come back to life.
      onResumeRide: () {
        final ride = ref.read(interruptedRideProvider).valueOrNull;
        if (ride == null) return;
        unawaited(resumeInterrupted(ride));
      },
      // Declining that offer. Routed through the orchestration rather than
      // answered on Screen 1, because a declined ride still owes History a row:
      // the rider is saying the journey finished, not that it never happened.
      onDeclineRide: () => unawaited(declineInterrupted()),
      onHistory: showHistory,
      onSettings: openSettings,
    );
  }
}
