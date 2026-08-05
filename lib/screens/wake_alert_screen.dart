import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/fill_or_scroll.dart';
import '../widgets/pressable.dart';

/// The wake alert. The screen the entire product exists to put in front of a
/// sleeping rider.
///
/// Frame drawn 29 Jul 2026. Two things in it were corrected against what the
/// wake engine actually does:
///
/// THE LADDER HAS NO TOTAL. The frame read "rung 2 of 4". WakeEscalation's
/// rungVolumes is [0.3, 0.6, 1.0], three steps, and _rung keeps incrementing
/// past the end while the volume holds at full. The ladder ends when the rider
/// ACKNOWLEDGES or when the train passes the ceiling station, never on a
/// count. Printing "of 4" would promise a sleeping rider that the alarm stops
/// by itself, which is the exact failure this app exists to prevent, so the
/// status line states the contract instead: it keeps getting louder until you
/// answer.
///
/// THE EARPHONE LINE IS A SOMETIMES-TRUE PROMISE, and it is left in
/// deliberately. On iOS, when the alarm has been forced into a ducked session
/// because another app holds audio, we are not the Now Playing owner and the
/// earphone tap goes to the music app instead (see the 24 Jul bench:
/// CannotInterruptOthers, printed 3/3). Threading that state through to the UI
/// was proposed once and called overengineering, correctly: the button below is
/// the affordance that ALWAYS works, and it is the loudest thing on the screen.
/// The earphone line sits under it as a hint, not as the instruction.
class WakeAlertScreen extends StatefulWidget {
  const WakeAlertScreen({
    super.key,
    required this.destinationName,
    required this.onAcknowledge,
    this.lastPassedLine,
    this.climbing = true,
    this.rung = 1,
  });

  /// Which rung the ladder is on, 1-based. Drives ONLY the glow's strength.
  ///
  /// The glow escalates with the sound, so a rider who surfaces mid-ladder can
  /// see how long it has been shouting at them without a number that lies about
  /// a total. It steps on rung change and never animates continuously, so it
  /// costs nothing between rungs.
  final int rung;

  /// The station the rider is being woken FOR.
  final String destinationName;

  /// "I'm awake". The one control, and the one that works in every audio state.
  final VoidCallback onAcknowledge;

  /// "Thakurli passed 19:49", or null when nothing has been passed yet. It is
  /// the rider's proof that the app was awake while they were not.
  final String? lastPassedLine;

  /// False once the ladder has reached full volume and is holding there.
  final bool climbing;

  @override
  State<WakeAlertScreen> createState() => _WakeAlertScreenState();
}

class _WakeAlertScreenState extends State<WakeAlertScreen> {
  /// Raised briefly when the rider tries to back out, to point at the way out.
  bool _nudging = false;

  /// What the ladder is actually doing, with no invented total.
  String get statusLine => widget.climbing
      ? 'Getting louder until you answer'
      : 'This will keep sounding until you answer';

  /// BACK IS REFUSED WHILE THE LADDER IS LIVE.
  ///
  /// Backing out would not stop the alarm: the ladder runs in the service and
  /// keeps climbing regardless. So a back press would leave the rider with a
  /// phone still escalating at full volume and the only working ack button gone
  /// from the screen, which is strictly worse than being held here. A
  /// half-asleep hand mashing back is exactly the case this exists for.
  ///
  /// It is not a trap: "I'm awake" is the largest thing on the screen, and back
  /// is ANSWERED rather than swallowed, by nudging that button so the way out
  /// is the thing that moves.
  ///
  /// Back is deliberately NOT treated as an acknowledgement. An accidental back
  /// must never silence an alarm.
  void _refusePop() {
    if (_nudging) return;
    setState(() => _nudging = true);
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _nudging = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _refusePop();
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final destinationName = widget.destinationName;
    final lastPassedLine = widget.lastPassedLine;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // THE MESSAGE SCROLLS, THE BUTTON NEVER DOES. A long station
              // name wraps the hero line to three (Chhatrapati Shivaji Maharaj
              // Terminus), and at a raised font size that ran 63 px past the
              // bottom on a 320 dp phone, which on this screen means the ack
              // button is the part that gets clipped. So the glyph and the
              // words live in their own flexible region and "I'm awake" is
              // pinned below it, at full size, always.
              Expanded(
                child: FillOrScroll(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(flex: 2),
                      _AlarmGlyph(rung: widget.rung),
                      const SizedBox(height: 32),
                      // HERO SCALE, and this is the second and last place in the app
                      // that earns it. Every other screen is read by someone awake;
                      // this one is read at arm's length by someone who is not, often
                      // in the dark, on a moving train. TypeScale.title was sized for
                      // an alert screen; this is sized for the reader.
                      Text(
                        'Wake up\n$destinationName is next',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 32,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Palette.text,
                        ),
                      ),
                      if (lastPassedLine != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          lastPassedLine,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: TypeScale.body,
                            // Lifted from 0.55. Half-asleep eyes in a dark carriage are
                            // not the eyes this palette's dim ladder was tuned for.
                            color: Palette.textDim(0.7),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Text(
                        statusLine,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: TypeScale.label,
                          color: Palette.textDim(0.6),
                        ),
                      ),
                      const Spacer(flex: 3),
                    ],
                  ),
                ),
              ),
              // The nudge answers a refused back press: the way out is the
              // thing that moves. Same curve and feel as every other press in
              // the app, just triggered by the system instead of a finger.
              AnimatedScale(
                scale: _nudging ? 1.04 : 1,
                duration: const Duration(milliseconds: 160),
                curve: const Cubic(0.23, 1, 0.32, 1),
                child: Pressable(
                  key: const Key('wake_ack'),
                  onTap: widget.onAcknowledge,
                  child: Container(
                    decoration: BoxDecoration(
                      // White, not crimson. Crimson starts or ends a JOURNEY, and
                      // this ends an alarm; the ride carries on afterwards.
                      color: Palette.text,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    // 88 tall, well past the 44 minimum. This is the ONE control
                    // on the screen and it is hunted for by a fumbling thumb in
                    // the dark, so it is sized to be hit without being aimed at.
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: const Center(
                      child: Text(
                        "I'm awake",
                        style: TextStyle(
                          fontSize: TypeScale.title,
                          fontWeight: FontWeight.w700,
                          color: Palette.ground,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'or press play/pause on your earphones',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TypeScale.caption,
                  color: Palette.textDim(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bell, in its glow.
///
/// STATIC. Every other screen in this app can afford restraint about motion for
/// battery reasons; this one cannot afford motion for a different reason. The
/// tone, the vibration and the volume ladder are already doing the waking, and
/// a pulsing glyph would compete with the one thing that must be found fast:
/// the button.
class _AlarmGlyph extends StatelessWidget {
  const _AlarmGlyph({required this.rung});

  final int rung;

  /// The glow tracks the sound. Rung 1 is close to the frame's drawn value and
  /// it climbs from there, so a rider who surfaces mid-ladder can SEE that it
  /// has been going a while.
  double get _glow => (0.34 + 0.10 * (rung - 1)).clamp(0.34, 0.62);

  @override
  Widget build(BuildContext context) {
    return Center(
      // Steps between rungs rather than snapping, and holds perfectly still in
      // between. A continuous pulse would compete with the button, which is the
      // one thing that has to be found fast.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: const Cubic(0.23, 1, 0.32, 1),
        width: 116,
        height: 116,
        decoration: BoxDecoration(
          color: Palette.surfaceGlass,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Palette.dotGreen.withValues(alpha: _glow),
              blurRadius: 46 + 8.0 * (rung - 1),
              spreadRadius: 10 + 3.0 * (rung - 1),
            ),
          ],
        ),
        child: const Icon(
          Icons.notifications,
          color: Palette.dotAmber,
          size: 54,
        ),
      ),
    );
  }
}
