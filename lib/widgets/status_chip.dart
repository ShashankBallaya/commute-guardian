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

    // Reduced motion takes the TRANSITIONS and never the states. The chip must
    // still say where the rider is; it just stops moving to say it.
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduced ? Duration.zero : const Duration(milliseconds: 200);

    // The Align sits OUTSIDE the press target on purpose. The chip hugs its
    // content and the Align stretches full width, so scaling the Align would
    // scale that full-width box and slide the chip toward the centre instead
    // of scaling it where it sits.
    return Align(
      alignment: Alignment.centerLeft,
      child: Pressable(
        key: const Key('status_chip'),
        onTap: onTap,
        // THE WIDTH CHANGES BETWEEN STATES, and it used to jump. "Locating..."
        // and "You're near: Dadar" and "Location unavailable. Tap to retry" are
        // three very different widths, so the chip resized instantly under the
        // thumb that had just tapped it. This is the one element on the screen
        // that says the app knows where the rider is, and a hard cut on it
        // reads as the app restarting rather than as the app answering.
        child: AnimatedSize(
          duration: duration,
          curve: Curves.easeOut,
          alignment: Alignment.centerLeft,
          child: _chipBody(dotColor, label, station, duration),
        ),
      ),
    );
  }

  Widget _chipBody(
    Color dotColor,
    String label,
    String? station,
    Duration duration,
  ) {
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
          // The dot TWEENS between states rather than snapping. Amber to green
          // is the moment the app found the rider, and a cut throws that away;
          // 200 ms of colour is enough to read as an answer arriving. Colour is
          // also the part of this that survives reduced motion, which is why
          // the dot keeps its transition when the size loses one.
          AnimatedContainer(
            duration: duration,
            curve: Curves.easeOut,
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
          // Flexible, because the chip's longest state is a sentence. "Location
          // unavailable. Tap to retry" is 34 characters, and at a raised font
          // size on a 320 dp phone it ran 291 px past the row (measured 5 Aug
          // 2026). It wraps rather than ellipsizing: the tail of that line is
          // the instruction, so it is the half that must not be cut.
          Flexible(
            // CROSS-FADED, not swapped. One sentence replacing another in the
            // same frame reads as a glitch; a fade reads as the chip changing
            // its mind. Keyed on the text itself so an identical label does not
            // fade to itself when some other part of the chip rebuilds.
            child: AnimatedSwitcher(
              duration: duration,
              child: Text.rich(
                key: ValueKey('$label$station'),
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
                style: TextStyle(
                  fontSize: TypeScale.body,
                  color: Palette.textDim(0.9),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
