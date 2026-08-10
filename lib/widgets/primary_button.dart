import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/type_scale.dart';
import 'pressable.dart';

/// The full-width action button, in the two weights this app has.
///
/// ONE DEFINITION, because there were about to be three. Screen 3 had this as a
/// private `_WideButton`, Screen 1's New journey had its own container, and the
/// debug screen was about to get a third when SlideToStart was retired. A
/// design system with three copies of its primary button is how a palette rule
/// quietly stops being true.
///
/// WHY THE PRIMARY IS WHITE AND NOT CRIMSON. Crimson means start or end a
/// JOURNEY, and nothing else may wear it. White means the primary action of the
/// screen in front of you, which is a different claim: on Screen 3 it starts
/// the ride, on Screen 1 it opens the picker. See [Palette.accent].
///
/// TAP, NEVER A DRAG, and that was argued rather than assumed (11 Aug 2026).
/// The debug screen used to start rides with a slide, on the reasoning that
/// both ends of a ride should be deliberate gestures and different ones. It
/// does not survive the product:
///
///   - Half asleep is the END of a ride, not the start. A rider on Screen 3 is
///     awake, boarding, and has just chosen a destination. That is why "hold to
///     confirm" is earned on End journey and nothing is earned here.
///   - A FAILED SLIDE IS A SILENT FAILURE OF THE CORE PROMISE. A partial drag
///     that snaps back on a crowded train looks much like one that worked, and
///     the cost is a rider who believes the alarm is armed when no ride is
///     running. A tap either changes the screen or does not.
///   - One-handed on a packed local, holding a rail and a bag, a full-width
///     target in the thumb zone beats a horizontal drag every time.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.enabled = true,
    this.radius = 16,
    this.verticalPadding = 18,
    this.fontSize = TypeScale.body,
  });

  final String label;

  /// Null-safe by construction: a disabled button is not merely unresponsive,
  /// it is visibly not ready (see [enabled]).
  final VoidCallback onTap;

  /// White fill for the primary action of a screen, glass for a secondary one
  /// that still deserves a full-width target.
  final bool filled;

  /// DIMMED AND INERT, never hidden. The debug screen's Start must be present
  /// before a journey is planned, because a control that appears out of nowhere
  /// reads as the app changing its mind. It also must not be pressable: running
  /// a ride nobody chose is worse than a dead tap.
  final bool enabled;

  final double radius;
  final double verticalPadding;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      decoration: filled
          ? BoxDecoration(
              color: enabled ? Palette.accent : Palette.textDim(0.25),
              borderRadius: BorderRadius.circular(radius),
              // No hairline on an opaque fill. A hairline exists to lift a
              // near-invisible glass surface off the ground and only muddies
              // the edge of a solid one.
              boxShadow: const [
                BoxShadow(
                  color: Palette.shadow,
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            )
          : Palette.glassCard(radius: radius),
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: filled
                ? (enabled ? Palette.onAccent : Palette.ground)
                : Palette.textDim(enabled ? 0.85 : 0.35),
          ),
        ),
      ),
    );

    if (!enabled) return body;
    return Pressable(onTap: onTap, child: body);
  }
}
