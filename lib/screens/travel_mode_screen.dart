import 'dart:async';

import 'package:flutter/material.dart';

import '../models/journey.dart';
import '../models/station.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';

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
    this.atStation = false,
    required this.wakeChoice,
    required this.onEndJourney,
    this.etaLine,
  });

  final Journey journey;

  /// Index into [Journey.chain] of the last station provably reached, or -1
  /// before the first.
  final int reachedIndex;

  /// Whether the train is standing IN the station at [reachedIndex]. The
  /// service's RideProgress decides this; the screen never re-derives it, for
  /// the same reason it does not re-derive [reachedIndex].
  final bool atStation;

  final WakeChoice wakeChoice;

  /// Held to confirm. An accidental brush must never end a ride the rider is
  /// asleep on.
  final VoidCallback onEndJourney;

  /// PHASE 3 SEAM. Null today, and the line is simply absent rather than
  /// guessed at.
  final String? etaLine;

  List<Station> get _chain => journey.chain;

  /// Stations still ahead, destination included.
  int get _stationsRemaining =>
      (_chain.length - 1 - reachedIndex).clamp(0, 999);

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
                  atStation: atStation,
                  collapsedCount: _collapsedCount,
                ),
              ),
              const SizedBox(height: 16),
              _WakeCard(choice: wakeChoice, destinationName: _destinationName),
              const SizedBox(height: 16),
              _EndJourneyButton(onConfirmed: onEndJourney),
            ],
          ),
        ),
      ),
    );
  }
}

/// When the wake alert fires. REPORTED BY THE SCREEN, not chosen on it.
///
/// Fixed at [lastTwoStations] today, which is the free tier's promise, and the
/// screen states it rather than offering it (see [_WakeCard]). Choosing it is a
/// Guardian Plus surface per the locked monetization design: free gets the
/// two-station warning, Plus sells the CHOICE and never adequacy. When Plus
/// exists it belongs in Settings, before a ride, not on the screen a
/// half-asleep rider is holding.
///
/// It has never touched leadTimeS, which stays locked at 90 s, nor the rule
/// that one acknowledgement stands the ladder down permanently.
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
                        letterSpacing: TypeScale.heroTracking,
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
                  style: TextStyle(
                    fontSize: TypeScale.body,
                    color: Palette.textDim(0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Flexible, so the badge gives way before the headline does. It is the
        // reassurance, not the news, and its two-line label grows with the
        // font size until it squeezes the station count into the gutter
        // (4.6 px past the row on a 320 dp phone, measured 5 Aug 2026).
        const Flexible(child: _ShieldBadge()),
      ],
    );
  }
}

/// The reassurance the rider checks before pocketing the phone.
///
/// A PILL, matching the status chip on Screen 1, since 11 Aug 2026. It used to
/// be a bare icon and a hard-wrapped two-line label with a `top: 6` nudge
/// holding it roughly level with the headline. Three things were wrong with
/// that, and the owner's report was simply "the shield is not perfectly
/// aligned":
///
///   - A 22 px icon centred against two lines of text sits level with the gap
///     BETWEEN them, so it reads as floating no matter what the padding says.
///   - The `\n` was hard, so it stacked even where a single line fitted, and it
///     was the two-line height that made the icon look wrong in the first place.
///   - With no container it is loose text beside a 46 px green number, which
///     reads as debris rather than as a badge. This app already had the answer:
///     Screen 1's chip is a glass pill with a mark and one line of text.
///
/// The copy shortened to fit one line. "Wake-up mode active" was 19 characters
/// and the previous shape existed to wrap it; a pill that wraps is not a pill.
/// The 5 Aug measurement that drove the old two-line label still stands (a
/// growing label squeezes the station count into the gutter on a 320 dp phone),
/// which is why the label ellipsises and the whole pill stays [Flexible]: it
/// gives way before the headline does, because it is the reassurance and not the
/// news.
class _ShieldBadge extends StatelessWidget {
  const _ShieldBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield, color: Palette.text, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Wake-up on',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TypeScale.caption,
                color: Palette.textDim(0.85),
              ),
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
    required this.atStation,
    required this.collapsedCount,
  });

  final List<Station> chain;
  final int reachedIndex;
  final bool atStation;
  final int collapsedCount;

  /// Behind the rider: the journey's own green, held well under the dots so it
  /// reads as track rather than as another row of information.
  static final Color _railTravelled = Palette.dotGreen.withValues(alpha: 0.45);

  /// Still to come.
  static final Color _railAhead = Palette.textDim(0.18);

  @override
  Widget build(BuildContext context) {
    // Built as descriptions first, then turned into widgets, because the rail
    // between two dots is a property of the PAIR: a row cannot know what colour
    // the line below it should be without knowing whether the row under it is
    // still ahead of the rider.
    final specs = <({_RowKind kind, String label, bool dimmed})>[];

    if (collapsedCount > 0) {
      specs.add((
        kind: _RowKind.passed,
        label: collapsedCount == 1
            ? '1 station passed'
            : '$collapsedCount stations passed',
        dimmed: true,
      ));
    }

    // AT A STATION, OR BETWEEN TWO. The 9 Aug ride is why this is two states.
    //
    // The screen used to draw the reached station as history and put "You are
    // here" underneath it, always. So a train standing on the platform at
    // Vithalwadi told the rider they were somewhere between Vithalwadi and
    // Ulhasnagar, which they could disprove by looking out of the window. The
    // owner's report, in his words: while the train is stationary at a station
    // it should still show you are in Vithalwadi.
    //
    // Naming the station IS the position when the rider is in it, so there is
    // one row, not two. "You are here" only appears when the honest answer is
    // that there is no station to name.
    final atNamedStation =
        atStation && reachedIndex >= 0 && reachedIndex < chain.length;

    if (atNamedStation) {
      specs.add((
        kind: _RowKind.here,
        label: chain[reachedIndex].name,
        dimmed: false,
      ));
    } else {
      if (reachedIndex >= 0 && reachedIndex < chain.length) {
        specs.add((
          kind: _RowKind.passed,
          label: chain[reachedIndex].name,
          dimmed: true,
        ));
      }
      specs.add((kind: _RowKind.here, label: 'You are here', dimmed: false));
    }

    for (var i = reachedIndex + 1; i < chain.length; i++) {
      final isDestination = i == chain.length - 1;
      specs.add((
        kind: isDestination ? _RowKind.destination : _RowKind.ahead,
        label: isDestination ? '${chain[i].name} (your stop)' : chain[i].name,
        dimmed: false,
      ));
    }

    // THE RAIL. Behind the dots, and it carries the same information the dots
    // do rather than repeating it: the line the rider has travelled is the
    // journey's colour, the line still to come is the quiet one. So the whole
    // card can be read at arm's length without reading a word of it, which is
    // how it is read on a moving train.
    final hereIndex = specs.indexWhere((spec) => spec.kind == _RowKind.here);
    final rows = <Widget>[
      for (var i = 0; i < specs.length; i++)
        _ChainRow(
          kind: specs[i].kind,
          label: specs[i].label,
          dimmed: specs[i].dimmed,
          railAbove: i == 0
              ? null
              : (i <= hereIndex ? _railTravelled : _railAhead),
          railBelow: i == specs.length - 1
              ? null
              : (i < hereIndex ? _railTravelled : _railAhead),
        ),
    ];

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
          // THE SECOND ANIMATED THING, and it earns its place for a different
          // reason than the count does. Arriving at a station REMOVES a row
          // (the dimmed name and "You are here" become one named row) and
          // leaving adds it back, so the whole list below jumps 40 px twice per
          // station. An element appearing or disappearing with no transition
          // reads as broken rather than as movement.
          //
          // Cheap where it matters: AnimatedSize costs nothing while the height
          // is unchanged, which on a 45 minute ride is nearly all of it. Still
          // no pulse, still no stagger, for the reasons in the class comment.
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: const Cubic(0.23, 1, 0.32, 1),
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rows,
            ),
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
    this.railAbove,
    this.railBelow,
  });

  final _RowKind kind;
  final String label;
  final bool dimmed;

  /// The rail joining this row's dot to the one above and the one below, or
  /// null at the two ends of the list where there is nothing to join to.
  ///
  /// PASSED BEHIND EACH ROW rather than drawn once down the card, because the
  /// rows are the only things that know where the dots actually sit. A single
  /// full-height line would have to guess the first and last dot centres, and
  /// would run past both into the collapsed summary row and the fade at the
  /// bottom.
  final Color? railAbove;
  final Color? railBelow;

  static const _rowHeight = 40.0;

  /// Half the row, so the two segments meet exactly at the dot's centre.
  static const _railHalf = _rowHeight / 2;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 40, not 44: on a 1080x1920 phone the whole chain plus the wake card and
      // the End button did not fit, and a rider mid-journey should be able to
      // see where they are without scrolling for it.
      height: _rowHeight,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            // HEIGHT IS LOAD-BEARING, and leaving it out drew nothing at all.
            // A Stack sizes itself to its largest NON-positioned child, which
            // here is the 22 px dot, so both rail halves were laid out against
            // 22 px instead of the row's 40 and collapsed to a hairline and to
            // nothing. Caught by rendering it, not by reading it.
            height: _rowHeight,
            // The rail is drawn FIRST so every dot sits on top of it. The
            // "here" dot carries a 10 px glow, and a line crossing over that
            // glow reads as a scratch through it.
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (railAbove != null)
                  Positioned(
                    top: 0,
                    bottom: _railHalf,
                    child: _rail(railAbove!),
                  ),
                if (railBelow != null)
                  Positioned(
                    top: _railHalf,
                    bottom: 0,
                    child: _rail(railBelow!),
                  ),
                _marker(),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: TypeScale.body,
                fontWeight: kind == _RowKind.here
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: dimmed ? Palette.textDim(0.5) : Palette.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Half of the line between two dots. 2 px, which is thin enough to read as
  /// track rather than as a border, and it lands on a whole pixel on the 3T's
  /// 3x density.
  static Widget _rail(Color color) => Container(width: 2, color: color);

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

/// What the alarm is going to do, stated. NOT a control.
///
/// IT WAS A SEGMENTED CONTROL UNTIL 11 AUG 2026, AND IT CHANGED NOTHING. The
/// class comment on [WakeChoice] has said so since it was written: the ladder
/// fires on its locked rules and nothing consumes the choice. So the ride screen
/// carried a prominent control that invited a tap and ignored it, and the owner
/// found exactly that on the device ("I can't toggle between Only destination
/// and Last 2 stops"). Two further faults fell out of the same card: the tap
/// could not redraw the screen at all, because it called setState on a host that
/// does not rebuild a pushed route, and the label and the toggle competed for
/// width so the control scaled below the 48 dp floor on a narrow phone.
///
/// All three go away by removing the control rather than repairing it, and the
/// removal is the correct product answer independently: CHOOSING the pre-warning
/// distance is a Guardian Plus surface by the locked monetization design, where
/// free gets the two-station warning and Plus sells the choice. It reappears in
/// Settings when Plus exists, not on the screen a half-asleep rider is holding.
///
/// What is left is the thing the rider actually wants at this moment, which is
/// to know what will happen without having to do anything: a sentence. The
/// [choice] still drives the wording, so the card cannot drift from the rule in
/// force, and it is the Phase 3 seam in the same shape [TravelModeScreen.etaLine]
/// already uses.
class _WakeCard extends StatelessWidget {
  const _WakeCard({required this.choice, required this.destinationName});

  final WakeChoice choice;
  final String destinationName;

  String get _line => switch (choice) {
    WakeChoice.lastTwoStations => '2 stations before $destinationName',
    WakeChoice.onlyDestination => 'at $destinationName',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          const Icon(Icons.notifications, color: Palette.text, size: 24),
          const SizedBox(width: 12),
          // Expanded now, not Flexible. There is no control left to give way
          // to, so the sentence gets the whole row, which is what stopped
          // "Wake me up before my stop" being squeezed onto three lines.
          Expanded(
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
                  _line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TypeScale.label,
                    color: Palette.textDim(0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
