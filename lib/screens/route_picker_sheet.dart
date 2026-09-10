import 'package:flutter/material.dart';

import '../models/route_option.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/pressable.dart';

/// C7c. The rider chooses her corridor, in the one place she cannot miss it.
///
/// ADR 0004, reported by a tester standing in Ghansoli: "I can go to CST
/// through Vashi and through Thane. My choice kaha se jau." The planner used to
/// answer with one route and never say that another existed, which is a
/// correctness bug with a safety hole under it. `WakeEscalation` walks the
/// interchanges the PLAN requires; a rider on another corridor never reaches
/// the one it is waiting at, the cursor never advances, and there is no alarm
/// at her stop at all.
///
/// A STEP, NOT A ROW IN THE COMMIT WINDOW, and that is the owner's call taken
/// against the ADR's own words ("default, do not block"). The ADR's argument
/// was that the 3 second commit window already catches a mis-tap, and three
/// seconds is not long enough to read two route cards, so the window was being
/// credited with a choice it never really offered. This appears before the
/// window, only when there is more than one way, and the window then runs
/// afterwards untouched.
///
/// IT BLOCKS, AND IT CANNOT TRAP. Every dismissal is a decision, not a dead
/// end: the scrim, the drag and the system back all mean "the one you had
/// already", which is the route a rider who never looks gets today. That is the
/// half of "do not block" worth keeping. A sheet that a pocketed phone could
/// leave sitting there, with no ride running and nothing said, would be a worse
/// failure than the one this fixes.
///
/// WHY A SHEET RATHER THAN A SCREEN. The journey she is starting stays on
/// screen behind it. A pushed screen would replace "Dadar to CSMT" with a list
/// of routes and make her hold the destination in her head while she reads
/// them.
Future<List<String>?> showRoutePicker({
  required BuildContext context,
  required String destinationName,
  required List<RouteOption> options,
  required List<String>? chosenChainIds,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    // OPAQUE, and Palette says why in its own words: [surfaceSolid] exists
    // "for surfaces that must stay opaque because they float over arbitrary
    // content (sheets, snackbars)". The glass fill is nearly invisible alone
    // and only reads as a card against the flat ground.
    backgroundColor: Palette.surfaceSolid,
    barrierColor: Palette.ground.withValues(alpha: 0.72),
    // The list is short by construction, and the number is MEASURED rather
    // than capped: over 809 sampled pairs the worst on the whole network is
    // four (see `routeOptionsProvider`). ADR 0004's cap of six is unreachable
    // and deliberately not implemented. A long interchange chain at x1.3 text
    // is not short, so this scrolls rather than overflows.
    isScrollControlled: true,
    showDragHandle: false,
    // AN EDGE, BECAUSE FILL ALONE IS NOT ONE. Seen on the 3T at real size: the
    // sheet ground (#111926) against the dimmed scaffold behind it separates by
    // a few points of luminance, so the panel read as a slightly lighter
    // region rather than as a surface that had arrived. `Palette.glassCard`
    // never relies on fill either; it always carries the hairline as well.
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: Palette.hairline),
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => RoutePickerSheet(
      destinationName: destinationName,
      options: options,
      chosenChainIds: chosenChainIds,
    ),
  );
}

/// The sheet's body, separated from [showRoutePicker] so a widget test can
/// pump it without a route stack.
class RoutePickerSheet extends StatelessWidget {
  const RoutePickerSheet({
    super.key,
    required this.destinationName,
    required this.options,
    required this.chosenChainIds,
  });

  final String destinationName;
  final List<RouteOption> options;

  /// What she is riding right now, so the sheet can say which one that is. Null
  /// on the ordinary journey, where the first option is the default.
  final List<String>? chosenChainIds;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final current = chosenChainIds;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Never taller than most of the screen, so the ride she is starting is
        // still visible above it. That is the whole reason this is a sheet.
        constraints: BoxConstraints(maxHeight: media.size.height * 0.78),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Which way to $destinationName?',
                    style: const TextStyle(
                      fontSize: TypeScale.title,
                      fontWeight: FontWeight.w600,
                      color: Palette.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    // NAMES THE CONSEQUENCE, because it is the reason the
                    // question is worth asking at all. She is not picking a
                    // preference, she is telling the app which stations to
                    // wake her at.
                    'We wake you at the changes on the route you pick.',
                    style: TextStyle(
                      fontSize: TypeScale.label,
                      height: 1.4,
                      color: Palette.textDim(0.6),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                itemCount: options.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final option = options[index];
                  return _RouteCard(
                    option: option,
                    // The first is what the planner would have given her
                    // silently, and it stays first: offering a choice must not
                    // move what a rider who never looks already gets.
                    isDefault: index == 0,
                    isCurrent: current != null && option.isChain(current),
                    onTap: () => Navigator.of(context).pop(option.chainIds),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar that says this sheet can be pulled down.
///
/// Material's own `showDragHandle` is off because it draws from the theme's
/// colour scheme rather than from [Palette], and this app's dark glass system
/// is locked (Figma reviews, 05-09 Jul 2026, palette revised 16 Jul).
///
/// NOT because a guard test would have caught it: `pressable_test.dart` bans
/// five widget names (the Material buttons and InkWell) and a drag handle is
/// none of them. The rule is real, the enforcement here is the palette.
class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 12, bottom: 10),
        decoration: BoxDecoration(
          color: Palette.textDim(0.18),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// One way to make the journey.
class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.option,
    required this.isDefault,
    required this.isCurrent,
    required this.onTap,
  });

  final RouteOption option;
  final bool isDefault;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        // 48 dp is the floor for anything a rider hits standing on a moving
        // train. Two lines plus this padding measure about 68, so it clears the
        // floor with room rather than by a hair, and the padding is what does
        // it rather than a minimum that could be silently lost.
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        decoration: Palette.glassCard(radius: 18).copyWith(
          // ONE ELEVATION SIGNAL, not two. The chosen route is said with the
          // border it already has, brightened, rather than with a second fill
          // or a coloured edge. Crimson is not available here at any strength:
          // it means END A RIDE and nothing else may wear it.
          border: Border.all(
            color: isCurrent ? Palette.textDim(0.34) : Palette.hairline,
          ),
        ),
        child: Row(
          // TOP ALIGNED, not centred. Centred, the marker landed in the gap
          // between the route name and its numbers and read as belonging to
          // neither. It labels the ROUTE, so it sits on the route's line.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.viaLabel ?? 'Direct, no change',
                    style: const TextStyle(
                      fontSize: TypeScale.bodyLarge,
                      fontWeight: FontWeight.w600,
                      color: Palette.text,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    option.factsLine,
                    style: TextStyle(
                      fontSize: TypeScale.label,
                      color: Palette.textDim(0.62),
                    ),
                  ),
                ],
              ),
            ),
            if (isCurrent || isDefault) ...[
              const SizedBox(width: 10),
              // Optical, not mathematical: the marker is 12.5 against a 16
              // semibold, so matching the box tops leaves it riding high. Two
              // pixels drops it onto the same visual line.
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _Marker(label: isCurrent ? 'Riding this' : 'Usual'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A quiet word, not a badge.
class _Marker extends StatelessWidget {
  const _Marker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: TypeScale.caption,
        fontWeight: FontWeight.w500,
        // 0.48, NOT THE 0.45 THIS WAS FIRST WRITTEN AT, and the background has
        // to be named or the number cannot be checked. Against the CARD FILL it
        // sits on (`surfaceGlass`, #121B29), white at 45 percent is 4.41:1, under
        // the 4.5:1 floor for text this size; 0.48 is 4.84:1 and looks the same.
        // Measured against the scaffold ground instead it reads 4.60:1, which is
        // the wrong surface and the reason a review disputed these digits.
        color: Palette.textDim(0.48),
      ),
    );
  }
}
