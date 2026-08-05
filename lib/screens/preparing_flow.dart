import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_output_gateway.dart';
import '../services/permissions_gateway.dart';
import '../state/journey_providers.dart';
import 'preparing_screen.dart';

/// Screen 3, wired: everything that has to be true before a rider pockets the
/// phone, in order, ending in a ride or in the rider backing out.
///
/// THE GATE DECIDES BEFORE IT SHOWS. [PreparingGate.check] runs the cheap
/// probes first, and when they all pass this flow is never pushed at all, so
/// the common ride goes straight from the pick to a running ride with no
/// screen in between. That matters more than it sounds: the fix is normally
/// already held (Screen 1 acquires one on open), so a flow that pushed itself
/// unconditionally would flash a progress screen for a few hundred
/// milliseconds on every single journey, which is worse than not existing.
///
/// Pops TRUE to start the ride, FALSE (or null, on a system back) to abandon.
class PreparingFlow extends ConsumerStatefulWidget {
  const PreparingFlow({
    super.key,
    required this.destinationName,
    required this.report,
    this.permissions = const PermissionsGateway(),
    this.audio = const AudioOutputGateway(),
  });

  final String destinationName;
  final PreparingReport report;
  final PermissionsGateway permissions;
  final AudioOutputGateway audio;

  @override
  ConsumerState<PreparingFlow> createState() => _PreparingFlowState();
}

enum _Stage { locating, notLocated, backgroundLocation, preflight }

class _PreparingFlowState extends ConsumerState<PreparingFlow> {
  late _Stage _stage;
  String? _originName;
  bool _earphonesConnected = true;

  @override
  void initState() {
    super.initState();
    _earphonesConnected = widget.report.earphonesConnected;
    if (widget.report.hasFix) {
      _originName = widget.report.originName;
      _stage = _afterFix();
    } else {
      _stage = _Stage.locating;
      Future.microtask(_locate);
    }
  }

  /// What is left to ask once the origin is known.
  _Stage _afterFix() {
    if (!widget.report.backgroundLocationGranted) {
      return _Stage.backgroundLocation;
    }
    return _Stage.preflight;
  }

  Future<void> _locate() async {
    // WAIT FOR THE STATIONS FIRST. locate() returns early and silently when the
    // repository has not loaded, leaving the state on "locating", which this
    // method would otherwise read as a failed fix and answer with "We can't
    // find you yet". A rider who picked a destination before the asset finished
    // parsing would have been told GPS failed when it was never asked.
    try {
      await ref.read(stationRepositoryProvider.future);
    } catch (_) {
      if (mounted) setState(() => _stage = _Stage.notLocated);
      return;
    }
    if (!mounted) return;

    await ref.read(nearestStationProvider.notifier).locate();
    if (!mounted) return;
    final fix = ref.read(nearestStationProvider);
    if (fix.state != GpsState.located) {
      setState(() => _stage = _Stage.notLocated);
      return;
    }
    // The origin is ALREADY SET by now: locate() goes through applyFix, which
    // is the one gate for every fix source and fills the origin itself when the
    // rider has not picked one. Setting it again here would be a second writer
    // on the same field.
    setState(() {
      _originName = fix.stationName;
      _stage = _afterFix();
    });
    _settleIfClear();
  }

  /// Leaves immediately when nothing is left to say.
  void _settleIfClear() {
    if (_stage == _Stage.preflight && _earphonesConnected) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _recheckEarphones() async {
    final connected = await widget.audio.earphonesConnected();
    if (!mounted) return;
    setState(() => _earphonesConnected = connected);
    _settleIfClear();
  }

  @override
  Widget build(BuildContext context) {
    final destination = widget.destinationName;

    return switch (_stage) {
      _Stage.locating => PreparingScreen(
        originName: _originName,
        destinationName: destination,
        steps: const [
          PrepStep(
            label: 'Finding you',
            detail: 'This can take a few seconds indoors',
            status: PrepStatus.active,
          ),
          PrepStep(label: 'Watching for your stop', status: PrepStatus.pending),
          PrepStep(
            label: 'Direction',
            detail: 'Confirmed once the train moves',
            status: PrepStatus.pending,
          ),
        ],
        onCancel: () => Navigator.of(context).pop(false),
      ),
      _Stage.notLocated => CannotLocateScreen(
        originName: _originName,
        destinationName: destination,
        onRetry: () {
          setState(() => _stage = _Stage.locating);
          unawaited(_locate());
        },
        // NOTE: there is no manual origin picker yet, so this returns the
        // rider to where they came from rather than opening one. It is the
        // one control on Screen 3 that does not yet do what it says.
        onSetStation: () => Navigator.of(context).pop(false),
      ),
      _Stage.backgroundLocation => BackgroundLocationScreen(
        originName: _originName,
        destinationName: destination,
        onOpenSettings: () async {
          await widget.permissions.openSettings();
          if (context.mounted) Navigator.of(context).pop(false);
        },
        onStartAnyway: () {
          setState(() => _stage = _Stage.preflight);
          _settleIfClear();
        },
      ),
      _Stage.preflight => PreflightScreen(
        originName: _originName,
        destinationName: destination,
        steps: [
          if (!_earphonesConnected)
            const PrepStep(
              label: "Your earphones aren't connected",
              detail: 'The alarm will play out loud',
              status: PrepStatus.active,
            ),
          PrepStep(label: 'Watching for $destination', status: PrepStatus.done),
        ],
        onStart: () => Navigator.of(context).pop(true),
        onRecheck: () => unawaited(_recheckEarphones()),
      ),
    };
  }
}

/// What the cheap probes found. Built by [PreparingGate.check].
class PreparingReport {
  const PreparingReport({
    required this.hasFix,
    required this.originName,
    required this.backgroundLocationGranted,
    required this.earphonesConnected,
  });

  final bool hasFix;
  final String? originName;
  final bool backgroundLocationGranted;
  final bool earphonesConnected;

  /// Nothing to show. The ride starts and Screen 3 never appears, which is the
  /// normal case.
  bool get clear => hasFix && backgroundLocationGranted && earphonesConnected;
}

/// Runs the probes that decide whether Screen 3 is needed at all.
class PreparingGate {
  const PreparingGate({
    this.permissions = const PermissionsGateway(),
    this.audio = const AudioOutputGateway(),
  });

  final PermissionsGateway permissions;
  final AudioOutputGateway audio;

  Future<PreparingReport> check(WidgetRef ref) async {
    final fix = ref.read(nearestStationProvider);
    final hasFix = fix.state == GpsState.located;
    final granted = await permissions.hasAlways();
    final earphones = await audio.earphonesConnected();
    return PreparingReport(
      hasFix: hasFix,
      originName: hasFix ? fix.stationName : null,
      backgroundLocationGranted: granted,
      earphonesConnected: earphones,
    );
  }
}
