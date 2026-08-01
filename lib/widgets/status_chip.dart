import 'package:flutter/material.dart';

import '../state/journey_providers.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import 'pressable.dart';

/// "You're near: Dadar", the quiet live chip at the top of every pre-ride
/// screen.
///
/// The chip body stays a quiet dark surface and the DOT ALONE carries status
/// colour, which is a locked design rule: never make the chip itself loud.
/// A tap asks for a fresh fix, because one 8 second attempt at launch is a
/// coin flip indoors on an old phone (14 Jul bench, twice), so a miss must
/// never read as a final verdict.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.state,
    required this.stationName,
    required this.onTap,
  });

  final GpsState state;
  final String? stationName;

  /// The owner of the callback decides when a tap is meaningful; mid-ride the
  /// service stream owns the chip and a tap does nothing.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (dotColor, label, station) = switch (state) {
      GpsState.locating => (Palette.dotAmber, 'Locating...', null),
      GpsState.located => (Palette.dotGreen, "You're near: ", stationName),
      // Dim, not red. Unavailable is inactive, not an error, and the only red
      // in this palette is the journey CTA. See Palette's class comment.
      GpsState.unavailable => (
          Palette.textDim(0.25),
          'Location unavailable. Tap to retry',
          null,
        ),
    };

    // The Align sits OUTSIDE the press target on purpose. The chip hugs its
    // content and the Align stretches full width, so scaling the Align would
    // scale that full-width box and slide the chip toward the centre instead
    // of scaling it where it sits.
    return Align(
      alignment: Alignment.centerLeft,
      child: Pressable(
        key: const Key('status_chip'),
        onTap: onTap,
        child: _chipBody(dotColor, label, station),
      ),
    );
  }

  Widget _chipBody(Color dotColor, String label, String? station) {
    return Container(
      decoration: Palette.glassCard(radius: 28),
      // 13, not 12. At 12 the chip measured 47 dp, one under the 48 dp touch
      // minimum, found on 1 Aug 2026 by the floor test added to Screen 1 while
      // trimming buttons that were too LARGE. It matters more here than the
      // size suggests: this chip is the GPS retry, and it exists because one
      // 8 second fix at launch is a coin flip indoors on an old phone.
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              // The glow is the "live/tracking now" signal, locked at 40%.
              boxShadow: state == GpsState.located
                  ? [
                      BoxShadow(
                        color: Palette.dotGreen.withValues(alpha: 0.4),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Text.rich(
            TextSpan(
              text: label,
              children: [
                if (station != null)
                  TextSpan(
                    text: station,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
            style: TextStyle(fontSize: TypeScale.body, color: Palette.textDim(0.9)),
          ),
        ],
      ),
    );
  }
}
