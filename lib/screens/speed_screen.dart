import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/ride_speed.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';

/// How fast the train is going. Opened from Screen 4, never part of it.
///
/// WHY IT IS ITS OWN SCREEN. The locked rule is that motion is allowed on
/// Screen 1 and forbidden on Screen 4, and the reason given is not taste:
/// Screen 4 is held in a pocket for 45 minutes. That rule protects a surface
/// that may be rendering while nobody watches. This one is only ever open
/// because a rider deliberately opened it, so it is by definition being looked
/// at, and when the phone goes back in the pocket it is not drawn at all.
///
/// THE NUMBER DOES NOT ANIMATE, and that is a decision rather than an omission.
/// A new reading arrives about once a second while this is open. The animation
/// rule is that something seen that often should not animate: a fade on every
/// tick would blur the one thing the screen exists to show, and cost frames for
/// the privilege. What DOES animate is the change between having a reading and
/// not having one, which is rare, and jarring if it snaps.
///
/// AND NOTHING IS INTERPOLATED BETWEEN FIXES. A needle gliding smoothly from 78
/// to 84 is drawing speeds the train was never measured at. On a product whose
/// whole claim is that it knows where you are, inventing data to look smooth is
/// not a trade worth making.
class SpeedScreen extends ConsumerStatefulWidget {
  const SpeedScreen({super.key});

  @override
  ConsumerState<SpeedScreen> createState() => _SpeedScreenState();
}

class _SpeedScreenState extends ConsumerState<SpeedScreen> {
  /// Drives the STALENESS check and nothing else.
  ///
  /// Without it a screen opened while the stream is dead would show the last
  /// reading forever, because no new fix ever arrives to rebuild it. The rider
  /// would watch a confident 80 km/h on a train standing at a signal. One
  /// second is the smallest useful tick and it costs a comparison.
  Timer? _stale;

  @override
  void initState() {
    super.initState();
    _stale = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stale?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speed = ref.watch(rideSpeedProvider);
    final shown = speed.shownKmh(DateTime.now());

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('speed_back'),
                    padding: EdgeInsets.zero,
                    // 48, not the 44 the history header uses. The floor is 48
                    // and this screen is new, so it starts at the floor rather
                    // than inheriting an old miss.
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: Icon(
                      Icons.chevron_left,
                      color: Palette.textDim(0.7),
                      size: 30,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Speed',
                    style: TextStyle(
                      fontSize: TypeScale.heading,
                      fontWeight: FontWeight.w600,
                      color: Palette.text,
                    ),
                  ),
                ],
              ),
              Expanded(child: Center(child: _Readout(kmh: shown))),
              _FastestLine(maxKmh: speed.maxKmh),
            ],
          ),
        ),
      ),
    );
  }
}

/// The number, or the honest absence of one.
class _Readout extends StatelessWidget {
  const _Readout({required this.kmh});

  final double? kmh;

  @override
  Widget build(BuildContext context) {
    // The ONE animated thing here, and it earns it: this crosses between two
    // states rather than between two values, which happens rarely and looks
    // broken when it snaps. 200 ms, ease-out, fade only. No slide: a number
    // that moves as it changes is harder to read, and reading it is the point.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: const Cubic(0.23, 1, 0.32, 1),
      switchOutCurve: const Cubic(0.23, 1, 0.32, 1),
      child: kmh == null
          ? const _NoReading(key: ValueKey('no_reading'))
          : _Reading(kmh: kmh!, key: const ValueKey('reading')),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.kmh, super.key});

  final double kmh;

  @override
  Widget build(BuildContext context) {
    // WHOLE NUMBERS. A decimal place on a GPS speed is false precision, and it
    // also makes the number change width constantly, which reads as flicker.
    final rounded = kmh.round();
    // A REAL ZERO IS NOT A MISSING READING. The train is standing at a
    // platform, and saying so is more use than a bare 0.
    final stopped = rounded == 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$rounded',
          key: const Key('speed_value'),
          style: const TextStyle(
            fontSize: 96,
            height: 1,
            letterSpacing: -2,
            fontWeight: FontWeight.w700,
            color: Palette.text,
            // Tabular figures, so 88 and 111 do not shove the layout sideways
            // once a second. Without this the number visibly jitters.
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          stopped ? 'Stopped' : 'km/h',
          key: const Key('speed_unit'),
          style: TextStyle(
            fontSize: TypeScale.bodyLarge,
            color: Palette.textDim(stopped ? 0.75 : 0.55),
          ),
        ),
      ],
    );
  }
}

/// What the screen says when the platform will not say.
///
/// A DASH, NEVER A ZERO. Both platforms report -1 to mean "no reading", and
/// every desk log this project has is full of it. Zero would tell a rider on a
/// moving train that they are stopped, which is the one lie this screen must
/// not tell.
class _NoReading extends StatelessWidget {
  const _NoReading({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '—',
          key: const Key('speed_no_reading'),
          style: TextStyle(
            fontSize: 96,
            height: 1,
            fontWeight: FontWeight.w700,
            color: Palette.textDim(0.35),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Waiting for a GPS reading',
          style: TextStyle(
            fontSize: TypeScale.bodyLarge,
            color: Palette.textDim(0.55),
          ),
        ),
      ],
    );
  }
}

/// The part a rider repeats to somebody else.
class _FastestLine extends StatelessWidget {
  const _FastestLine({required this.maxKmh});

  final double? maxKmh;

  @override
  Widget build(BuildContext context) {
    // Reserved rather than hidden: appearing from nothing would shift the
    // readout above it the first time a fix lands.
    return SizedBox(
      height: 24,
      child: Center(
        child: maxKmh == null
            ? const SizedBox.shrink()
            : Text(
                'Fastest this ride ${maxKmh!.round()} km/h',
                key: const Key('speed_fastest'),
                style: TextStyle(
                  fontSize: TypeScale.body,
                  color: Palette.textDim(0.55),
                ),
              ),
      ),
    );
  }
}
