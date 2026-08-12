import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/fill_or_scroll.dart';
import '../widgets/pressable.dart';

/// Screen 5, Arrival. The last thing a ride shows.
///
/// Frame approved 30 Jul 2026, and it draws ONE of the two states this screen
/// actually has. The second was found by reading WindDown rather than the frame,
/// which is the fifth time that check has caught something.
///
/// THE COUNTDOWN DOES NOT START ON ARRIVAL. WindDown arms when the destination
/// arrival is announced, and only starts counting after two walking-speed fixes
/// more than 150 m from where the train stopped. On the 18 Jul Kalyan log that
/// was about six minutes after the doors opened, stairs pauses included. So the
/// headline is on screen long before the ring has any time to show.
///
/// THE TWO STATES COLLAPSE FROM THREE. "Arrived, waiting for you to leave" and
/// "disarmed, auto-off is never coming" (the rider got back on, or the train
/// pulled out with them aboard) are indistinguishable to a rider: no countdown,
/// and the only way out is ending it yourself. They differ only in WHY, which
/// the rider does not care about. So [autoEndAt] being null covers both.
///
/// END NOW MEANS TWO DIFFERENT THINGS, and the caller owns the difference.
/// WindDown.endNow() early-returns unless the countdown is running, so in the
/// no-countdown state it would be a dead button. There it has to run the normal
/// ride teardown instead. This screen just reports the press; [onEndNow] is
/// wired to the right path by whoever shows the screen.
class ArrivalScreen extends StatefulWidget {
  const ArrivalScreen({
    super.key,
    required this.destinationName,
    required this.summaryLine,
    required this.onEndNow,
    this.autoEndAt,
    this.window = const Duration(seconds: 60),
    this.onExtend,
    this.onSaveRoute,
    this.onDismissSave,
    this.clock = DateTime.now,
  });

  /// Where "now" comes from.
  ///
  /// Injected because this is the house pattern, not because a screen is
  /// special: RideProgress, WakeEscalation and WindDown all take their time as
  /// a parameter, which is what makes six real ride logs replayable. A widget
  /// that reads the wall clock directly cannot be tested at all, since pumping
  /// a test clock forward does not move `DateTime.now()`.
  final DateTime Function() clock;

  /// "Kalyan". The station the rider is standing at, which after an overshoot
  /// is NOT necessarily the destination they picked.
  final String destinationName;

  /// "52 min • 18 stations • Dadar → Kalyan". Composed by the caller because
  /// the pieces come from the ride record, not from this screen.
  final String summaryLine;

  /// When Travel Mode ends by itself, or null when nothing is counting.
  ///
  /// NULL IS THE FIRST STATE AND THE LONGER ONE. See the class comment.
  final DateTime? autoEndAt;

  /// The full countdown window, which is what the ring's arc is a fraction of.
  /// 60 s normally; WindDown.extension makes it 10 minutes after an Extend.
  final Duration window;

  /// Ends Travel Mode now. See the class comment: this is NOT always
  /// WindDown.endNow.
  final VoidCallback onEndNow;

  /// Buys ten more minutes. Null in the no-countdown state, where there is
  /// nothing to extend, and the button is simply absent rather than disabled.
  final VoidCallback? onExtend;

  /// The rider named this route "Home" or "Work". Null hides the save card,
  /// which is what a route already saved should do.
  final ValueChanged<String>? onSaveRoute;

  /// "Not now", and do not ask again for this ride.
  final VoidCallback? onDismissSave;

  @override
  State<ArrivalScreen> createState() => _ArrivalScreenState();
}

class _ArrivalScreenState extends State<ArrivalScreen> {
  Timer? _tick;

  /// Dismissed for this ride only. Not persisted: "not now" is an answer about
  /// this moment, and a rider who declines once should still be offered the
  /// route the next time they finish it.
  bool _saveDismissed = false;

  /// The label the rider just chose, or null if they have not.
  ///
  /// A tap on Home has to CHANGE something on the screen. Leaving the card sat
  /// there with its two buttons still offered reads as a press that did not
  /// land, and this rider is walking down a platform, not watching for a
  /// database write. The card is replaced by the confirmation, in place, so
  /// nothing below it moves.
  String? _savedAs;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ArrivalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// The screen owns its own clock, and that is not a second projector.
  ///
  /// It holds no state about the RIDE; it renders a deadline the service gave
  /// it. A countdown that does not count would need something above it to
  /// rebuild every second for no reason, which is worse.
  void _syncTicker() {
    final counting = widget.autoEndAt != null;
    if (counting && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!counting) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration? get _remaining {
    final endsAt = widget.autoEndAt;
    if (endsAt == null) return null;
    final left = endsAt.difference(widget.clock());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    final showSave = widget.onSaveRoute != null && !_saveDismissed;
    final savedAs = _savedAs;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The summary block scrolls; the save card and the buttons do
              // not. Six stacked blocks (glyph, headline, ring, summary, save
              // card, two buttons) is the fullest state this app has, and with
              // a long station name it ran 160 px past the bottom of a 320 dp
              // phone. End now is what must survive that, so it is pinned.
              Expanded(
                child: FillOrScroll(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // flex 1, not 2. With the save card present the counting state
                      // has six stacked blocks and the top spacer was eating room the
                      // content needed, pushing the summary line into the card.
                      const Spacer(),
                      const _ArrivedGlyph(),
                      const SizedBox(height: 18),
                      Text(
                        "You've arrived at ${widget.destinationName}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: TypeScale.display,
                          letterSpacing: TypeScale.displayTracking,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: Palette.text,
                        ),
                      ),
                      const SizedBox(height: 22),
                      if (remaining != null)
                        _CountdownRing(
                          remaining: remaining,
                          window: widget.window,
                        )
                      else
                        // No ring, because there is no time to show. The line states
                        // the contract instead, which is the same move the wake alert
                        // makes when it refuses to invent a rung total.
                        Text(
                          'Travel Mode stays on until you leave the station.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: TypeScale.body,
                            height: 1.35,
                            color: Palette.textDim(0.6),
                          ),
                        ),
                      const SizedBox(height: 22),
                      Text(
                        widget.summaryLine,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: TypeScale.caption,
                          color: Palette.textDim(0.5),
                        ),
                      ),
                      // Minimum breathing room BEFORE the flexible gap, so the summary
                      // never ends up touching the save card when the spacer collapses.
                      const SizedBox(height: 24),
                      const Spacer(flex: 2),
                    ],
                  ),
                ),
              ),
              if (savedAs != null) ...[
                _SavedConfirmation(label: savedAs),
                const SizedBox(height: 16),
              ] else if (showSave) ...[
                _SaveRouteCard(
                  onSave: (label) {
                    setState(() => _savedAs = label);
                    widget.onSaveRoute!(label);
                  },
                  onDismiss: () {
                    setState(() => _saveDismissed = true);
                    widget.onDismissSave?.call();
                  },
                ),
                const SizedBox(height: 16),
              ],
              _Actions(onEndNow: widget.onEndNow, onExtend: widget.onExtend),
            ],
          ),
        ),
      ),
    );
  }
}

/// The arrival marker: green circle checkmark in the same glow the live
/// position dot carries. Checkmark means COMPLETED and the plain dot means
/// live; the two meanings are kept apart deliberately.
///
/// STATIC. The rider sees this once per ride, which is rare enough to earn an
/// entrance, but the screen it opens is one they must read and act on, and a
/// moving glyph would pull against the button that is the point of the screen.
class _ArrivedGlyph extends StatelessWidget {
  const _ArrivedGlyph();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          color: Palette.dotGreen,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              // The locked live-dot glow value. Same light, different meaning,
              // and that consistency is what makes the meaning readable.
              color: Palette.dotGreen.withValues(alpha: 0.4),
              blurRadius: 26,
              spreadRadius: 6,
            ),
          ],
        ),
        child: const Icon(Icons.check, size: 40, color: Palette.text),
      ),
    );
  }
}

/// The auto-off countdown: dim track, bright arc on top, clockwise from twelve.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.remaining, required this.window});

  final Duration remaining;
  final Duration window;

  /// The countdown is big, but deliberately NOT [TypeScale.hero]. Hero belongs
  /// to Screen 4's remaining-station count and nothing else, and the loudest
  /// thing on THIS screen has to be the button, not the clock.
  static const _digits = 30.0;

  /// 116, down from the frame's 148, and the stroke down from 6 to 5.
  ///
  /// TWO REASONS, both found on the 3T and neither visible in a 390pt frame.
  /// The frame draws the ring at 39 of 60 seconds, so a third of it is dim; on
  /// arrival it is at 60 of 60 and the whole circle is a bright white band,
  /// which at the frame's weight became the loudest thing on the screen and
  /// beat the End now button. The locked rule is that the loudest element is
  /// the primary action. And the full state (glyph, headline, ring, summary,
  /// save card, two buttons) simply did not have the room on a 1080x1920
  /// phone: everything was touching.
  static const _size = 116.0;
  static const _stroke = 5.0;

  /// CEILING, not truncation, and this is the difference between a clock and a
  /// clock that is wrong. A 60 second window read with `inSeconds` opens at
  /// 0:59, because a few milliseconds have already gone by the time the first
  /// frame paints, and the rider never sees the full minute they were promised.
  /// Rounding up shows 1:00 for the whole first second and reaches 0:00 exactly
  /// when the time is actually up, which is how every countdown a rider has
  /// ever seen behaves.
  String get _label {
    final total = (remaining.inMilliseconds / 1000).ceil();
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    // The ARC uses raw milliseconds, not the rounded-up label, so it sweeps
    // smoothly rather than in the same steps the digits take.
    final windowMs = window.inMilliseconds;
    final fraction = windowMs <= 0
        ? 0.0
        : (remaining.inMilliseconds / windowMs).clamp(0.0, 1.0);
    final reduced = MediaQuery.disableAnimationsOf(context);

    return Center(
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Linear, and exactly one second long, so the arc glides between
            // ticks instead of stepping 6 degrees at a time. Constant motion is
            // the one case where linear is right; any easing here would make a
            // clock look like it was speeding up and slowing down.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: fraction, end: fraction),
              duration: reduced ? Duration.zero : const Duration(seconds: 1),
              curve: Curves.linear,
              builder: (context, value, _) => CustomPaint(
                size: const Size.square(_size),
                painter: _RingPainter(fraction: value, stroke: _stroke),
              ),
            ),
            // The RING is a fixed 116 dp and stays that way: its diameter was
            // chosen against the End now button on the 3T, and a circle that
            // grew with the font size would take that decision back. So the
            // digits inside adapt instead. At a raised font size they ran
            // 10 px past the circle (measured 5 Aug 2026), which clipped the
            // "auto end" line under them.
            Padding(
              padding: const EdgeInsets.all(_stroke * 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _label,
                      style: const TextStyle(
                        fontSize: _digits,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: Palette.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'auto end',
                      style: TextStyle(
                        fontSize: TypeScale.caption,
                        color: Palette.textDim(0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.stroke});

  /// Time remaining, 1 to 0.
  final double fraction;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inset = rect.deflate(stroke / 2);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Palette.textDim(0.15);
    canvas.drawArc(inset, 0, math.pi * 2, false, track);

    if (fraction <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      // Not pure white. At the start of a ride the arc is a nearly complete
      // circle, and at full brightness that band out-shouted the End now
      // button on the 3T.
      ..color = Palette.textDim(0.82);
    // From twelve o'clock, clockwise. Never crimson: crimson starts or ends a
    // journey, and a clock does neither, however time-critical it looks.
    canvas.drawArc(inset, -math.pi / 2, math.pi * 2 * fraction, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.stroke != stroke;
}

/// The moment "save this route" finally has a home.
///
/// It was homeless from 16 Jul, when the save star came off the Screen 2 rows
/// (a mis-tap hazard beside a live trigger), until this frame. Journey end is
/// the right place for a reason: the route has proven real, and SavedRoute
/// needs a LABEL, which is a thing you can only sensibly ask for once the rider
/// knows what they just did.
class _SaveRouteCard extends StatelessWidget {
  const _SaveRouteCard({required this.onSave, required this.onDismiss});

  final ValueChanged<String> onSave;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Save this route?',
            style: TextStyle(
              fontSize: TypeScale.bodyLarge,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'One tap next time.',
            style: TextStyle(
              fontSize: TypeScale.caption,
              color: Palette.textDim(0.6),
            ),
          ),
          const SizedBox(height: 14),
          // TWO ROWS, NOT THREE CONTROLS ON ONE. Home, Work and Not now side
          // by side measured about 40 dp tall against the locked 48 dp floor
          // (11 dp of padding around a 15 px line cannot reach it), and on a
          // 320 dp phone the three of them ran 107 px past the card. Splitting
          // them buys the height back: the two labels share the width, and Not
          // now gets its own full-width row, which also puts the destructive
          // choice where a thumb will not find it by accident.
          Row(
            children: [
              Expanded(child: _label('Home')),
              const SizedBox(width: 10),
              Expanded(child: _label('Work')),
            ],
          ),
          const SizedBox(height: 8),
          Pressable(
            key: const Key('save_route_not_now'),
            onTap: onDismiss,
            child: Padding(
              // 15, not 11: 15 + 15 around a 15 px line is 48 dp exactly.
              padding: const EdgeInsets.symmetric(vertical: 15),
              child: Center(
                child: Text(
                  'Not now',
                  style: TextStyle(
                    fontSize: TypeScale.body,
                    color: Palette.textDim(0.55),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String name) => Pressable(
    key: Key('save_route_${name.toLowerCase()}'),
    onTap: () => onSave(name),
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.textDim(0.22)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: Center(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: TypeScale.body,
            fontWeight: FontWeight.w600,
            color: Palette.text,
          ),
        ),
      ),
    ),
  );
}

/// What a tap on Home or Work leaves behind.
///
/// It says where the route went, because "Saved" on its own tells a rider
/// nothing they can act on later. Not a toast: a toast on this screen would be
/// gone before a rider walking down a platform looked back at their phone, and
/// it would slide over the End now button on its way out.
class _SavedConfirmation extends StatelessWidget {
  const _SavedConfirmation({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('save_route_confirmation'),
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Palette.dotGreen, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Saved as $label. One tap from home next time.',
              style: TextStyle(
                fontSize: TypeScale.body,
                height: 1.3,
                color: Palette.textDim(0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// End now, and Extend when there is something to extend.
///
/// CRIMSON ON END NOW ONLY. Ending the ride is exactly what the palette
/// reserves crimson for. Extend is the opposite of ending, so it stays glass,
/// and the pair reads faster when only one of them is loud.
class _Actions extends StatelessWidget {
  const _Actions({required this.onEndNow, required this.onExtend});

  final VoidCallback onEndNow;
  final VoidCallback? onExtend;

  @override
  Widget build(BuildContext context) {
    final extend = onExtend;

    final endNow = Pressable(
      key: const Key('arrival_end_now'),
      onTap: onEndNow,
      child: Container(
        decoration: BoxDecoration(
          color: Palette.crimson,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: const Center(
          child: Text(
            'End now',
            style: TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
        ),
      ),
    );

    // NO HOLD TO CONFIRM, unlike Screen 4's End journey. That gesture exists
    // because a pocket-tap must not end a ride the rider is asleep on. Here the
    // rider has arrived, is holding the phone, and the ride is ending in under
    // a minute anyway, so a hold would be ceremony guarding nothing.
    if (extend == null) return endNow;

    return Row(
      children: [
        Expanded(child: endNow),
        const SizedBox(width: 12),
        Expanded(
          child: Pressable(
            key: const Key('arrival_extend'),
            onTap: extend,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Palette.textDim(0.25)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: const Center(
                child: Text(
                  'Extend 10 min',
                  style: TextStyle(
                    fontSize: TypeScale.heading,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
