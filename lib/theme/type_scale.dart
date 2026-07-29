/// The app's type scale, set from Screen 4.
///
/// WHY SCREEN 4 IS THE REFERENCE: it is the only screen whose sizing was chosen
/// against the owner's actual phone rather than against a Figma frame. The
/// frames are drawn at 390x844; the 3T is 1080x1920, relatively shorter and
/// narrower, and on 29 Jul 2026 the frame's scale both looked oversized there
/// and genuinely overflowed (124 px on Screen 4's header row, 25 px on its
/// toggle). The owner approved the reduced scale on the device and asked for it
/// across every screen, which is what this file is.
///
/// Sizes only. Weight and colour stay with the widget, because those carry
/// meaning here (crimson once per screen, the dim ladder in Palette.textDim)
/// and a scale that tried to own them would flatten decisions that were made
/// screen by screen for good reasons.
abstract final class TypeScale {
  /// The remaining-station count on Screen 4, and nothing else. The only number
  /// in the app big enough to be read from a pocket at arm's length.
  static const hero = 46.0;

  /// A screen's opening promise, used once. Screen 1's "Doze off. We'll wake
  /// you before your stop."
  static const display = 22.0;

  /// A route, a destination, the subject of the screen.
  static const title = 20.0;

  /// A screen's own name, and the label on a primary button.
  static const heading = 18.0;

  /// A row that takes a tap. Larger than [body] on purpose: a target a rider
  /// hits while standing on a moving train.
  static const bodyLarge = 16.0;

  /// A row that is read, not pressed.
  static const body = 15.0;

  /// The quiet second line under a row.
  static const label = 13.5;

  /// Metadata, and anything the rider only needs if they go looking.
  static const caption = 12.5;
}
