import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// The locked motif: dim dots on a hairline with a glowing green dot, a train
/// on a line. Free-floating dots are banned, they read as a carousel indicator.
///
/// Two jobs, one shape. As DECORATION (Screen 1's first run) the glow sits at
/// the head of the line. As PROGRESS (onboarding) the glow is the rider's
/// position and the line behind it is the ground already covered, which is the
/// same language the active-journey timeline speaks: solid behind, dim ahead.
class MiniRail extends StatelessWidget {
  const MiniRail({super.key, this.stops = 5, this.current});

  /// Total dots, including the glowing one.
  final int stops;

  /// Zero-based position of the glow. Null puts it at the head, which is the
  /// decorative form.
  final int? current;

  @override
  Widget build(BuildContext context) {
    final position = current ?? stops - 1;
    return SizedBox(
      height: 14,
      child: Row(
        children: [
          for (var i = 0; i < stops; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 1,
                  // Covered ground reads brighter, exactly as the journey
                  // timeline's solid rail does above the live position.
                  color: i <= position
                      ? Palette.textDim(0.28)
                      : Palette.textDim(0.12),
                ),
              ),
            if (i == position)
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Palette.dotGreen,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Palette.dotGreen.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              )
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i < position
                      ? Palette.textDim(0.32)
                      : Palette.textDim(0.18),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
