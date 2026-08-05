import 'package:flutter/material.dart';

/// Fills the viewport when the content fits, scrolls when it does not.
///
/// Added 5 Aug 2026, after `overflow_test.dart` measured every screen at every
/// size it will meet and found clipping on five of them.
///
/// The screens in this app are bottom-anchored: a Spacer at the top pushes the
/// actions into the thumb zone. That layout is right, and it is also the layout
/// that clips, because a Column with a Spacer has no answer when its children
/// no longer fit. The two cases it has to survive are a long station name
/// (Chhatrapati Shivaji Maharaj Terminus wraps to three lines where Kalyan
/// takes one) and a rider running Android's font size above default, which is
/// exactly the rider most likely to need waking.
///
/// So: keep the Spacers, and give the Column somewhere to go. The minHeight
/// makes the content at least a screen tall, so the Spacers still absorb the
/// slack and nothing moves on a phone with room. IntrinsicHeight is what lets a
/// Spacer live inside a scrollable at all: it gives the Column a tight height
/// (its own intrinsic, or the viewport, whichever is larger), and a flex child
/// needs a bounded height to divide.
///
/// NOT FOR THE ONE-CONTROL SCREENS. The wake alert and the arrival screen keep
/// their button OUTSIDE this, pinned to the bottom. A rider being woken must
/// never have to scroll to find "I'm awake".
class FillOrScroll extends StatelessWidget {
  const FillOrScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          // Clamping, not bouncing: a screen that jiggles under a thumb when
          // there was nothing to scroll to reads as broken.
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(child: child),
          ),
        );
      },
    );
  }
}
