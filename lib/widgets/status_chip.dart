import 'package:flutter/material.dart';

import '../state/journey_providers.dart';
import '../theme/palette.dart';

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

    return GestureDetector(
      key: const Key('status_chip'),
      onTap: onTap,
      child: _chipBody(dotColor, label, station),
    );
  }

  Widget _chipBody(Color dotColor, String label, String? station) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        decoration: Palette.glassCard(radius: 28),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
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
              style: TextStyle(fontSize: 15, color: Palette.textDim(0.9)),
            ),
          ],
        ),
      ),
    );
  }
}
