import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// Press feedback for this app's tappable surfaces.
///
/// WHY THIS EXISTS: until 29 Jul 2026 every tappable thing on Screens 1 and 2
/// was a bare GestureDetector, so a tap produced NOTHING visible until the next
/// screen arrived. That gap is worst exactly where this app puts its most
/// important taps: picking a destination STARTS A JOURNEY, and starting one
/// does database and GPS work on a phone that is frequently an old one, so the
/// silence between the tap and the response is long enough for a rider to
/// wonder whether it registered and tap again.
///
/// Material's InkWell ripple is deliberately NOT used. This is a custom dark
/// glass system and a ripple reads as stock Android, which is the one thing
/// [Palette]'s whole locked design exists to avoid.
///
/// Two shapes, because one does not fit both:
///   [Pressable]    SCALES. For self-contained surfaces: cards, the CTA, the
///                  status chip.
///   [PressableRow] TINTS. For rows inside a card, where a scale would pull the
///                  row away from the card edges it is aligned to and read as
///                  the row coming loose.

/// Down fast, back slower. The press is the system answering the rider, so it
/// has to be immediate; the release is only the surface settling and can take
/// its time. Both sit inside the 100 to 160 ms band that press feedback lives
/// in: past that a press stops feeling like a press and starts feeling like a
/// transition.
const _pressDown = Duration(milliseconds: 110);
const _pressRelease = Duration(milliseconds: 160);

/// A strong ease-out. Flutter's stock curves are too soft to read at 110 ms:
/// the whole point is that the movement is over almost before it is seen, and a
/// gentle curve at this duration just looks like a dropped frame.
const _pressCurve = Cubic(0.23, 1, 0.32, 1);

/// A surface that scales down slightly while held.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.child,
    this.scale = 0.97,
    this.behavior = HitTestBehavior.opaque,
  });

  final VoidCallback onTap;
  final Widget child;

  /// Kept subtle on purpose. Deeper than about 0.95 on a full-width card moves
  /// the edges far enough to read as the card jumping rather than responding.
  final double scale;

  /// Opaque by default: the WHOLE surface is the target. Flutter's default,
  /// deferToChild, would make an undecorated child a silent dead zone, which is
  /// the exact failure this widget exists to prevent.
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _setDown(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion takes the SCALE, never the tap. A scale is movement, which
    // is the category that causes motion sickness; the gesture itself is not
    // decoration and must survive.
    final reduced = MediaQuery.disableAnimationsOf(context);

    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _setDown(true),
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down && !reduced ? widget.scale : 1,
        duration: _down ? _pressDown : _pressRelease,
        curve: _pressCurve,
        child: widget.child,
      ),
    );
  }
}

/// A row inside a card that tints while held.
///
/// The tint is a COLOUR change, not movement, so it survives reduced motion:
/// it is the only thing telling the rider the row heard them, and removing it
/// would leave the highest-stakes tap on Screen 2 silent again.
class PressableRow extends StatefulWidget {
  const PressableRow({
    super.key,
    required this.onTap,
    required this.child,
    this.radius = 12,
  });

  final VoidCallback onTap;
  final Widget child;
  final double radius;

  @override
  State<PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<PressableRow> {
  bool _down = false;

  void _setDown(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so the whole row is the target, including the gaps between the
      // station name and its code.
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setDown(true),
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: _down ? _pressDown : _pressRelease,
        curve: _pressCurve,
        decoration: BoxDecoration(
          // Faint on purpose: it sits on glass that is already barely lighter
          // than the ground, and anything stronger reads as a selected state
          // that persists rather than a press that passes.
          color: Palette.textDim(_down ? 0.06 : 0),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      ),
    );
  }
}
