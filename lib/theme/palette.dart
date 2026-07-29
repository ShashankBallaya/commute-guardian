import 'package:flutter/material.dart';

/// The locked design system (Figma reviews, 05-09 Jul 2026, palette revised
/// 16 Jul 2026): dark navy ground, translucent navy glass surfaces, white text.
/// The burgundy surfaces and cream text of the earlier reviews are retired.
/// Crimson fill is reserved for the one action that starts or ends a journey;
/// nothing else may use it. The green dot means live/tracking, amber means
/// acquiring.
///
/// There is deliberately NO status red. "Location unavailable" uses a dim dot,
/// because unavailable reads as inactive rather than as an error, and a second
/// red would blur the rule that crimson means start or end a journey. Settled
/// 28 Jul 2026, closing an item the design notes had left open since 16 Jul.
abstract final class Palette {
  /// The scaffold ground.
  static const ground = Color(0xFF0F1722);

  /// A deeper ground, for wells recessed into [ground].
  static const groundDeep = Color(0xFF0D141D);

  /// The glass surface fill (172335 at 20%). Nearly invisible alone: over
  /// [ground] it composites to within a few points of the ground itself, so it
  /// only reads as a card alongside [hairline] and [shadow]. Prefer
  /// [glassCard] over reaching for this directly.
  static const surface = Color(0x33172335);

  /// [surface] pre-composited over [ground], for surfaces that must stay opaque
  /// because they float over arbitrary content (sheets, snackbars).
  static const surfaceSolid = Color(0xFF111926);

  /// The glass card fill, and the value the WIREFRAME FRAMES actually draw.
  ///
  /// The wireframe disagrees with itself, found 29 Jul 2026. Its token board
  /// documents the glass as `#172335 @ 20%` (solid #111926) and its rendered
  /// phone frames use `rgba(23,35,53,.35)`, which composites over [ground] to
  /// #121B29. Every frame the owner has designed against is the lighter one, so
  /// that is the one the app follows; the token board is the stale half.
  ///
  /// Opaque for the same reason [glassCard] stopped using [surface]: a
  /// translucent fill lets the card's own drop shadow bleed through it.
  static const surfaceGlass = Color(0xFF121B29);

  static const hairline = Color(0x14FEFEFE);
  static const shadow = Color(0x33000000);

  static const text = Color(0xFFFEFEFE);
  static const dotGreen = Color(0xFF3AB16C);
  static const dotAmber = Color(0xFFD9A03D);

  /// dotGreen at 20%, the soft green wash: the selected segment of the Screen 4
  /// wake toggle. Not the live-dot glow, which is locked at 40%.
  static const greenSoft = Color(0x333AB16C);

  /// Figma gives the CTA as 83111A at 60% over [ground]. This is that composite,
  /// kept opaque so the fill cannot shift when content scrolls beneath it.
  static const crimson = Color(0xFF55131D);

  static Color textDim(double opacity) => text.withValues(alpha: opacity);

  /// Fill, hairline border and shadow together: a glass card that is right by
  /// construction. No blur, it has nothing to bite on a flat ground (see the
  /// glassmorphism note in the design system).
  ///
  /// THE FILL IS OPAQUE, and it has to be. Measured off the 3T on 29 Jul 2026:
  /// with the translucent [surface] the card's own drop shadow showed THROUGH
  /// its own fill, and the shadow darkened more than the fill lightened. Card
  /// interiors came out at #0F1521 against a #0F1722 ground, so every glass
  /// surface in the app was rendering DARKER than the background it was meant
  /// to sit above. The lift was not weak, it was inverted.
  ///
  /// [surfaceSolid] is [surface] already composited over [ground], so this is
  /// the colour the design always intended (#111926); making it opaque changes
  /// nothing about the intent and only stops the shadow bleeding through. The
  /// ground is flat, so there is never anything behind a card worth seeing.
  static BoxDecoration glassCard({double radius = 20}) => BoxDecoration(
        color: surfaceGlass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: hairline),
        boxShadow: const [
          BoxShadow(color: shadow, blurRadius: 24, offset: Offset(0, 8)),
        ],
      );
}
