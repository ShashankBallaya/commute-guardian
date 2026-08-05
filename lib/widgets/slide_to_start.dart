import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/type_scale.dart';

/// Slide to start a journey.
///
/// THE MIRROR OF HOLD-TO-END. Both ends of a ride are deliberate gestures, and
/// deliberately different ones: you slide to begin and you hold to stop, so a
/// half-asleep rider reaching for the phone cannot do one while meaning the
/// other. Starting is the cheaper mistake of the two, which is why this is a
/// slide rather than another hold.
///
/// Crimson, because starting a journey is exactly what the palette reserves
/// crimson for.
///
/// A FLICK COUNTS. Requiring the thumb to travel the whole track is the common
/// way to get this wrong: it makes a confident gesture feel like work. Past
/// roughly a third of the way, a quick release completes on VELOCITY, the same
/// rule a swipe-to-dismiss uses. A slow drag still has to cross most of the
/// track, because a slow drag is not yet a decision.
class SlideToStart extends StatefulWidget {
  const SlideToStart({
    super.key,
    required this.label,
    required this.onStart,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onStart;

  /// A disabled track does not move at all. It reads as unavailable rather than
  /// broken, which is what a track that slides and then snaps back would say.
  final bool enabled;

  @override
  State<SlideToStart> createState() => _SlideToStartState();
}

class _SlideToStartState extends State<SlideToStart>
    with SingleTickerProviderStateMixin {
  /// 64, not 68. The track replaced a button that was two pixels shorter, and
  /// the difference overflowed the debug screen's column by 1 px. Still a
  /// comfortable target: the thumb alone is 52 by 52.
  static const _height = 64.0;
  static const _thumbInset = 6.0;

  /// Past this, a flick finishes the job. Below it, no amount of speed does:
  /// a stray brush near the left edge must never start a ride.
  static const _flickThreshold = 0.33;

  /// A slow drag has to get most of the way there on its own.
  static const _commitThreshold = 0.78;

  /// Above this, the release was a flick and not a drift. Borrowed from the
  /// same rule swipe-to-dismiss uses.
  static const _flickVelocity = 0.6;

  /// EAGER, not `late final`. Lazily creating this meant that on a track the
  /// rider never touched, its first access was dispose(), which builds a ticker
  /// with `vsync: this` against an already-deactivated widget. The disabled
  /// case is exactly the case that never drags, so the bug lived precisely
  /// where nothing would have exercised it by hand.
  late final AnimationController _settle;

  double _progress = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      // Snap back is FAST, because the system is only answering. The drag
      // itself is as slow as the rider's thumb, because that is where the
      // deciding happens.
      duration: const Duration(milliseconds: 220),
    )..addListener(() => setState(() => _progress = _settle.value));
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _snapBack() {
    _settle
      ..value = _progress
      ..animateTo(0, curve: const Cubic(0.23, 1, 0.32, 1));
  }

  void _complete() {
    setState(() => _progress = 1);
    widget.onStart();
    // Reset behind the transition, so a rider who comes back to this screen
    // does not find a track sitting at the far end.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _progress = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final travel = constraints.maxWidth - _height - _thumbInset;

        return GestureDetector(
          key: const Key('slide_to_start'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled
              ? (_) {
                  _settle.stop();
                  setState(() => _dragging = true);
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) {
                  if (travel <= 0) return;
                  setState(() {
                    _progress = (_progress + details.delta.dx / travel).clamp(
                      0.0,
                      1.0,
                    );
                  });
                }
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (details) {
                  setState(() => _dragging = false);
                  final flicked =
                      details.velocity.pixelsPerSecond.dx / 1000 >
                          _flickVelocity &&
                      _progress > _flickThreshold;
                  if (_progress >= _commitThreshold || flicked) {
                    _complete();
                  } else {
                    _snapBack();
                  }
                }
              : null,
          child: SizedBox(
            height: _height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // surfaceGlass, not surface: the translucent token
                      // composites to the OLD glass value and left the disabled
                      // track a shade darker than every card around it.
                      color: widget.enabled
                          ? Palette.crimson
                          : Palette.surfaceGlass,
                      borderRadius: BorderRadius.circular(18),
                      border: widget.enabled
                          ? null
                          : Border.all(color: Palette.hairline),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Center(
                    child: Opacity(
                      // The label fades as the thumb covers the track: by the
                      // time the gesture is committed there is nothing left to
                      // read, which is what makes the end of the slide feel
                      // like an arrival rather than a stop.
                      opacity: (1 - _progress * 1.6).clamp(0.0, 1.0),
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: TypeScale.heading,
                          fontWeight: FontWeight.w700,
                          color: widget.enabled
                              ? Palette.text
                              : Palette.textDim(0.35),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.enabled)
                  Positioned(
                    left: _thumbInset + _progress * travel,
                    top: _thumbInset,
                    bottom: _thumbInset,
                    child: _Thumb(pressed: _dragging),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.pressed});

  final bool pressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      // The same press feedback every other surface in this app gives, so the
      // thumb reads as part of the system rather than as a novelty control.
      scale: pressed ? 0.94 : 1,
      duration: const Duration(milliseconds: 110),
      curve: const Cubic(0.23, 1, 0.32, 1),
      child: Container(
        width: 56,
        decoration: BoxDecoration(
          color: Palette.text,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.chevron_right, color: Palette.ground, size: 28),
      ),
    );
  }
}
