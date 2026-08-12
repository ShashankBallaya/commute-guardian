import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/palette.dart';

/// A switch that behaves like a physical thing, for Screen 4's crowd-mode row.
///
/// WHY NOT Material's [Switch]. It shipped on 12 Aug 2026 and fails four of the
/// fluid-interface rules this project cares about, in ways a rider feels
/// without being able to name:
///
///   1. RESPONSE. It gives nothing on touch-down. Feedback that waits for
///      release reads as lag, and lag is where directness "falls off a cliff".
///   2. BEHAVIOR. It runs a fixed-duration curve. A curve cannot answer new
///      input; a spring can, because new input only moves the target.
///   3. INTERRUPTIBILITY. Grab it mid-flight and it finishes its animation
///      first. Every animation a finger can touch must be redirectable at any
///      instant, and must start from the CURRENT on-screen value rather than
///      the logical one, or it jumps.
///   4. HARMONY. No haptic on the frame the value commits. The visual and the
///      touch must land together or the illusion breaks.
///
/// THE MOTION BUDGET IS NOT VIOLATED. Screen 4's own rule is that exactly one
/// thing animates on a screen held in a pocket for 45 minutes, because battery
/// draw there is already over budget. This spring only runs while a finger is
/// on it or for the ~0.35 s after release, so it costs nothing on the journey.
class PulseSwitch extends StatefulWidget {
  const PulseSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Sized so the whole control clears the 48 dp floor this project measures
  /// against, with the visible track smaller than its target.
  static const trackWidth = 52.0;
  static const trackHeight = 31.0;
  static const thumbDiameter = 25.0;

  static double get _travel => trackWidth - thumbDiameter - 6;

  @override
  State<PulseSwitch> createState() => _PulseSwitchState();
}

class _PulseSwitchState extends State<PulseSwitch>
    with SingleTickerProviderStateMixin {
  /// 0 is off, 1 is on. UNBOUNDED on purpose: a spring may pass its target and
  /// come back, and clamping the controller would flatten exactly the part of
  /// the motion that reads as physical. The painting clamps instead.
  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
    value: widget.value ? 1 : 0,
  );

  bool _pressed = false;
  bool _dragging = false;

  /// Critically damped, response 0.35 s.
  ///
  /// Damping 1.0 is the default for ordinary UI: graceful, no overshoot,
  /// nothing to distract a rider who is only glancing. Bounce is reserved for
  /// motion the rider's own gesture threw, which is why a FLICK below gets a
  /// slightly springier one and a tap does not.
  static final _settle = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 322, // (2*pi/0.35)^2, so "response" is a time, not a guess.
    ratio: 1,
  );

  static final _thrown = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 322,
    ratio: 0.8,
  );

  @override
  void didUpdateWidget(PulseSwitch old) {
    super.didUpdateWidget(old);
    // The value changed from OUTSIDE (the row's own tap, or the provider
    // answering). Spring from wherever the thumb is right now.
    if (old.value != widget.value && !_dragging) {
      _springTo(widget.value ? 1 : 0, velocity: 0, spring: _settle);
    }
  }

  void _springTo(
    double target, {
    required double velocity,
    required SpringDescription spring,
  }) {
    if (_reducedMotion) {
      // Reduced motion means a gentler equivalent, not a dead control: the
      // thumb still moves, it just does not travel or overshoot.
      _pos.value = target;
      return;
    }
    _pos.animateWith(
      SpringSimulation(spring, _pos.value, target, velocity),
    );
  }

  bool get _reducedMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Commit, with the haptic on the SAME frame as the visual change. Causality
  /// and harmony: the touch answers the thing the rider just did, at the moment
  /// they did it.
  ///
  /// `selectionClick` and not a vibration pattern, deliberately. This app's own
  /// buzzes MEAN things (one tap is Pocket Pulse, an insistent burst is the
  /// wake alarm), and a control must never speak that vocabulary. This is the
  /// system's selection tick, it only fires with the screen in the rider's
  /// hand, and it never reaches the ride log.
  void _commit(bool next) {
    if (next == widget.value) return;
    unawaited(HapticFeedback.selectionClick());
    widget.onChanged(next);
  }

  void _onDragStart(DragStartDetails _) {
    setState(() {
      _dragging = true;
      _pressed = true;
    });
    _pos.stop(); // Grabbed mid-flight: take over from the current value.
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // 1:1 with the finger for the whole gesture, not a jump at the end.
    _pos.value = (_pos.value + details.delta.dx / PulseSwitch._travel).clamp(
      -0.15,
      1.15,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity =
        details.velocity.pixelsPerSecond.dx / PulseSwitch._travel;
    // THE SIGN OF THE VELOCITY DECIDES, not the position. A rider who flicks
    // left from the right-hand side means "off", even though the thumb is
    // still nearer "on" at the instant they let go.
    final flicked = velocity.abs() > 1.0;
    final next = flicked ? velocity > 0 : _pos.value > 0.5;
    setState(() {
      _dragging = false;
      _pressed = false;
    });
    // Velocity handed off, so there is no seam between the drag and the
    // settle, and a thrown thumb is allowed a little overshoot because the
    // gesture itself carried momentum.
    _springTo(
      next ? 1 : 0,
      velocity: velocity,
      spring: flicked ? _thrown : _settle,
    );
    _commit(next);
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: widget.value,
      // A LISTENER FOR THE PRESS, NOT onTapDown, and this is the whole point of
      // the rebuild rather than a detail of it. `onTapDown` waits for the
      // gesture ARENA to resolve, and this control deliberately has a drag
      // recognizer competing with its tap, so the arena holds the press
      // feedback for up to 100 ms. That is exactly the latency the control was
      // rebuilt to remove, and it was invisible until a test pumped 16 ms and
      // found the thumb had not moved. A raw pointer event has no arena.
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapCancel: () => setState(() => _pressed = false),
          onTap: () {
            setState(() => _pressed = false);
            final next = !widget.value;
            _springTo(next ? 1 : 0, velocity: 0, spring: _settle);
            _commit(next);
          },
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: SizedBox(
            height: 48,
            width: PulseSwitch.trackWidth + 12,
            child: Center(
              child: AnimatedBuilder(
                animation: _pos,
                builder: (context, _) {
                  final t = _pos.value.clamp(0.0, 1.0);
                  return CustomPaint(
                    size: const Size(
                      PulseSwitch.trackWidth,
                      PulseSwitch.trackHeight,
                    ),
                    painter: _PulseSwitchPainter(t: t, pressed: _pressed),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseSwitchPainter extends CustomPainter {
  const _PulseSwitchPainter({required this.t, required this.pressed});

  final double t;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    // The track colour crosses over WITH the thumb rather than switching at
    // the end, so the whole control moves as one thing.
    canvas.drawRRect(
      track,
      Paint()
        ..color = Color.lerp(Palette.textDim(0.12), Palette.greenSoft, t)!,
    );
    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Color.lerp(Palette.textDim(0.18), Palette.dotGreen, t * 0.5)!,
    );

    // The thumb WIDENS while held, which is the press feedback: it reads as
    // the control taking the weight of the finger.
    final grow = pressed ? 4.0 : 0.0;
    const d = PulseSwitch.thumbDiameter;
    final travel = size.width - d - 6;
    final left = 3 + travel * t;
    final thumb = RRect.fromRectAndRadius(
      Rect.fromLTWH(left - grow / 2, (size.height - d) / 2, d + grow, d),
      const Radius.circular(d / 2),
    );
    canvas.drawRRect(
      thumb,
      Paint()..color = Color.lerp(Palette.textDim(0.55), Palette.dotGreen, t)!,
    );
  }

  @override
  bool shouldRepaint(_PulseSwitchPainter old) =>
      old.t != t || old.pressed != pressed;
}
