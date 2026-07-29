import 'dart:async';

import 'package:flutter/material.dart';

import '../models/journey.dart';
import '../models/station.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/pressable.dart';

/// Screen 4, Travel Mode. The app's home for the whole journey.
///
/// Frame approved 16 Jul 2026 (v2), built 29 Jul. Everything here is drawn from
/// ONE number, [reachedIndex], which the service's own RideProgress publishes.
/// The UI could re-derive it from the raw fix stream it already receives, and
/// deliberately does not: that would be a second projector against the same
/// chain, and this project has been bitten by exactly that shape before.
///
/// NO ETA. The approved frame carries "Arriving 19:52 (estimate)" and there is
/// no ETA anywhere in the codebase; a live on-device estimate was decided on
/// 12 Jul and never built. Scoped to Phase 3 by the owner on 29 Jul rather than
/// shipped as a fabricated time, because a wrong arrival time on this screen is
/// worse than no arrival time: the whole product is a promise about when to
/// wake up. [etaLine] is the seam it will land on.
///
/// MOTION, and mostly the absence of it. This screen is OPEN IN A POCKET for
/// the length of a journey, and its battery draw is already over the handover's
/// budget at 9 to 10 percent an hour. So exactly one thing animates: the
/// remaining-station count, because a change there is the actual news and
/// happens every few minutes. Two things were deliberately NOT animated:
///   - The "you are here" dot does NOT pulse. A continuous animation on a
///     screen held for 45+ minutes is the one shape this app cannot afford, and
///     the glow already says "live" without costing a frame.
///   - The station list does NOT stagger in. Stagger is an entrance effect, and
///     this list is not entering; it is a place the rider keeps coming back to.
class TravelModeScreen extends StatelessWidget {
  const TravelModeScreen({
    super.key,
    required this.journey,
    required this.reachedIndex,
    required this.wakeChoice,
    required this.onWakeChoiceChanged,
    required this.onEndJourney,
    this.etaLine,
  });

  final Journey journey;

  /// Index into [Journey.chain] of the last station provably reached, or -1
  /// before the first.
  final int reachedIndex;

  final WakeChoice wakeChoice;
  final ValueChanged<WakeChoice> onWakeChoiceChanged;

  /// Held to confirm. An accidental brush must never end a ride the rider is
  /// asleep on.
  final VoidCallback onEndJourney;

  /// PHASE 3 SEAM. Null today, and the line is simply absent rather than
  /// guessed at.
  final String? etaLine;

  List<Station> get _chain => journey.chain;

  /// Stations still ahead, destination included.
  int get _stationsRemaining => (_chain.length - 1 - reachedIndex).clamp(0, 999);

  String get _destinationName => _chain.isEmpty ? '' : _chain.last.name;

  /// How many stations are collapsed behind the "N stations passed" row.
  ///
  /// The frame shows the last passed station in full and everything before it
  /// summarised. A rider mid-journey does not want to scroll through where they
  /// have been to find where they are.
  int get _collapsedCount => reachedIndex <= 0 ? 0 : reachedIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                stationsRemaining: _stationsRemaining,
                destinationName: _destinationName,
                etaLine: etaLine,
              ),
              const SizedBox(height: 20),
              // The card owns the flexible space and scrolls INSIDE its own
              // border. Scrolling the card as a whole clipped a row against the
              // card edge on the 3T, which reads as broken rather than as more
              // content below.
              Expanded(
                child: _ChainCard(
                  chain: _chain,
                  reachedIndex: reachedIndex,
                  collapsedCount: _collapsedCount,
                ),
              ),
              const SizedBox(height: 16),
              _WakeCard(
                choice: wakeChoice,
                onChanged: onWakeChoiceChanged,
              ),
              const SizedBox(height: 16),
              _EndJourneyButton(onConfirmed: onEndJourney),
            ],
          ),
        ),
      ),
    );
  }
}

/// When the wake alert fires.
///
/// NOTE FOR LATER: this control is the Guardian Plus surface per the locked
/// monetization design (free fires the pre-warning EARLIER, Plus sells the
/// CHOICE, never adequacy). MVP has no paywalls, so both options ship free.
/// It deliberately does NOT touch leadTimeS, which stays locked at 90 s, nor
/// the rule that one acknowledgement stands the ladder down permanently.
enum WakeChoice {
  /// Warned with two stations to go, then again at the destination.
  lastTwoStations,

  /// Only the destination.
  onlyDestination,
}

class _Header extends StatelessWidget {
  const _Header({
    required this.stationsRemaining,
    required this.destinationName,
    required this.etaLine,
  });

  final int stationsRemaining;
  final String destinationName;
  final String? etaLine;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // THE ONE ANIMATED THING ON THIS SCREEN, and the only one
                  // that earns it: the count changing IS the news, roughly once
                  // every few minutes. It rises as it fades, so the direction
                  // of travel reads without being read. Everything else here is
                  // static on purpose (see the class comment).
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: const Cubic(0.23, 1, 0.32, 1),
                    switchOutCurve: const Cubic(0.23, 1, 0.32, 1),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.35),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Text(
                      '$stationsRemaining',
                      key: ValueKey(stationsRemaining),
                      style: const TextStyle(
                        fontSize: TypeScale.hero,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: Palette.dotGreen,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Flexible: a two-digit count next to a long label overflowed
                  // this row by 124 px on a 3T. The number is the headline and
                  // never gives way; the label does.
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        stationsRemaining == 1 ? 'station to' : 'stations to',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TypeScale.body,
                          color: Palette.textDim(0.75),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                destinationName,
                style: const TextStyle(
                  fontSize: TypeScale.title,
                  fontWeight: FontWeight.w700,
                  color: Palette.text,
                ),
              ),
              if (etaLine != null) ...[
                const SizedBox(height: 2),
                Text(
                  etaLine!,
                  style: TextStyle(fontSize: TypeScale.body, color: Palette.textDim(0.6)),
                ),
              ],
            ],
          ),
        ),
        const _ShieldBadge(),
      ],
    );
  }
}

/// The reassurance the rider checks before pocketing the phone.
class _ShieldBadge extends StatelessWidget {
  const _ShieldBadge();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield, color: Palette.text, size: 22),
          const SizedBox(width: 7),
          Text(
            'Wake-up\nmode active',
            style: TextStyle(
              fontSize: TypeScale.caption,
              height: 1.25,
              color: Palette.textDim(0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChainCard extends StatelessWidget {
  const _ChainCard({
    required this.chain,
    required this.reachedIndex,
    required this.collapsedCount,
  });

  final List<Station> chain;
  final int reachedIndex;
  final int collapsedCount;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];

    if (collapsedCount > 0) {
      rows.add(
        _ChainRow(
          kind: _RowKind.passed,
          label: collapsedCount == 1
              ? '1 station passed'
              : '$collapsedCount stations passed',
          dimmed: true,
        ),
      );
    }

    // The last station actually reached, named in full.
    if (reachedIndex >= 0 && reachedIndex < chain.length) {
      rows.add(
        _ChainRow(
          kind: _RowKind.passed,
          label: chain[reachedIndex].name,
          dimmed: true,
        ),
      );
    }

    rows.add(const _ChainRow(kind: _RowKind.here, label: 'You are here'));

    for (var i = reachedIndex + 1; i < chain.length; i++) {
      final isDestination = i == chain.length - 1;
      rows.add(
        _ChainRow(
          kind: isDestination ? _RowKind.destination : _RowKind.ahead,
          label: isDestination
              ? '${chain[i].name} (your stop)'
              : chain[i].name,
        ),
      );
    }

    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      // The bottom edge FADES rather than cutting a row in half. On the 3T a
      // hard clip against the card border read as a broken row instead of as
      // more content below, which is the difference between a screen that looks
      // wrong and one that looks scrollable.
      child: ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.88, 1],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
  }
}

enum _RowKind { passed, here, ahead, destination }

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.kind,
    required this.label,
    this.dimmed = false,
  });

  final _RowKind kind;
  final String label;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 40, not 44: on a 1080x1920 phone the whole chain plus the wake card and
      // the End button did not fit, and a rider mid-journey should be able to
      // see where they are without scrolling for it.
      height: 40,
      child: Row(
        children: [
          SizedBox(width: 26, child: Center(child: _marker())),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: TypeScale.body,
                fontWeight:
                    kind == _RowKind.here ? FontWeight.w700 : FontWeight.w400,
                color: dimmed ? Palette.textDim(0.5) : Palette.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _marker() => switch (kind) {
        _RowKind.passed => Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Palette.dotGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, size: 14, color: Palette.text),
          ),
        // The glow is the same "live, tracking now" signal the status chip
        // carries, at the same locked 40%.
        _RowKind.here => Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Palette.dotGreen,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Palette.dotGreen.withValues(alpha: 0.4),
                  blurRadius: 10,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
        _RowKind.ahead => Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Palette.textDim(0.35), width: 1.5),
            ),
          ),
        _RowKind.destination => Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Palette.text, width: 1.5),
            ),
            child: const Icon(Icons.flag, size: 12, color: Palette.text),
          ),
      };
}

class _WakeCard extends StatelessWidget {
  const _WakeCard({required this.choice, required this.onChanged});

  final WakeChoice choice;
  final ValueChanged<WakeChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          const Icon(Icons.notifications, color: Palette.text, size: 24),
          const SizedBox(width: 12),
          // Flexible, not Expanded: on the 3T (1080 wide, narrower than the
          // 390pt frame) an Expanded label took the room the toggle needed and
          // wrapped "Wake me up before my stop" onto THREE lines. The label
          // gives way to the control, because the control is the thing a rider
          // came here to change.
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Wake me up',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TypeScale.body,
                    fontWeight: FontWeight.w700,
                    color: Palette.text,
                  ),
                ),
                Text(
                  'before my stop',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TypeScale.label, color: Palette.textDim(0.7)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // scaleDown, not shrink-to-nothing: the toggle keeps its drawn size
          // wherever it fits and only gives up pixels on a narrow phone, which
          // is what the 3T is next to the 390pt frame.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: _WakeToggle(choice: choice, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _WakeToggle extends StatelessWidget {
  const _WakeToggle({required this.choice, required this.onChanged});

  final WakeChoice choice;
  final ValueChanged<WakeChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(
            key: const Key('wake_last_two'),
            top: 'Last 2',
            bottom: 'stations',
            selected: choice == WakeChoice.lastTwoStations,
            onTap: () => onChanged(WakeChoice.lastTwoStations),
          ),
          _segment(
            key: const Key('wake_only_destination'),
            top: 'Only',
            bottom: 'destination',
            selected: choice == WakeChoice.onlyDestination,
            onTap: () => onChanged(WakeChoice.onlyDestination),
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required Key key,
    required String top,
    required String bottom,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Pressable(
      key: key,
      onTap: onTap,
      child: AnimatedContainer(
        // A select-class control, so it sits in the 150 to 250 ms band. The
        // wash used to snap, which made a deliberate choice feel like a
        // rendering glitch. greenSoft is the locked wash for a selected
        // segment.
        duration: const Duration(milliseconds: 180),
        curve: const Cubic(0.23, 1, 0.32, 1),
        decoration: BoxDecoration(
          color: selected ? Palette.greenSoft : Palette.greenSoft.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(11),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: TypeScale.label,
                color: selected ? Palette.dotGreen : Palette.text,
              ),
              child: Text(top),
            ),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: TypeScale.caption,
                color: selected
                    ? Palette.dotGreen.withValues(alpha: 0.85)
                    : Palette.textDim(0.7),
              ),
              child: Text(bottom),
            ),
          ],
        ),
      ),
    );
  }
}

/// Crimson, and the one place on this screen that may use it: ending a journey
/// is exactly what the palette reserves it for.
///
/// HOLD TO CONFIRM, because the rider is asleep and the phone is in a pocket.
/// The press is slow and deliberate; the release snaps back.
class _EndJourneyButton extends StatefulWidget {
  const _EndJourneyButton({required this.onConfirmed});

  final VoidCallback onConfirmed;

  @override
  State<_EndJourneyButton> createState() => _EndJourneyButtonState();
}

class _EndJourneyButtonState extends State<_EndJourneyButton> {
  static const _holdDuration = Duration(milliseconds: 1200);

  bool _held = false;
  Timer? _holdTimer;

  /// THE FILL AND THE CONFIRMATION MUST BE THE SAME EVENT.
  ///
  /// This used to fire on GestureDetector.onLongPress, which lands at Flutter's
  /// ~500 ms long-press threshold while the fill animates over 1200 ms. The
  /// journey therefore ended when the bar was about 40 percent across: the
  /// screen promised one thing and the button did another, on the one control
  /// that can stop a rider being woken. The timer runs for exactly the fill's
  /// duration, so what the rider watches IS what they are waiting for.
  void _setHeld(bool held) {
    if (_held == held) return;
    setState(() => _held = held);

    _holdTimer?.cancel();
    if (held) {
      _holdTimer = Timer(_holdDuration, () {
        if (!mounted) return;
        setState(() => _held = false);
        widget.onConfirmed();
      });
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);

    return GestureDetector(
      key: const Key('end_journey'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setHeld(true),
      onTapUp: (_) => _setHeld(false),
      onTapCancel: () => _setHeld(false),
      child: Stack(
        children: [
          Container(
            height: 82,
            decoration: BoxDecoration(
              color: Palette.crimson,
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          // The fill that grows while held. Slow on the way in because the
          // rider is deciding, instant on release because the system is only
          // answering. Under reduced motion it does not travel at all.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AnimatedFractionallySizedBox(
                duration: _held && !reduced
                    ? _holdDuration
                    : const Duration(milliseconds: 200),
                curve: _held ? Curves.linear : Curves.easeOut,
                alignment: Alignment.centerLeft,
                widthFactor: _held && !reduced ? 1 : 0,
                heightFactor: 1,
                child: ColoredBox(color: Palette.textDim(0.12)),
              ),
            ),
          ),
          SizedBox(
            height: 82,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'End journey',
                    style: TextStyle(
                      fontSize: TypeScale.heading,
                      fontWeight: FontWeight.w700,
                      color: Palette.text,
                    ),
                  ),
                  Text(
                    'hold to confirm',
                    style: TextStyle(
                      fontSize: TypeScale.caption,
                      color: Palette.textDim(0.8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
