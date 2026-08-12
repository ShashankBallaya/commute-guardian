import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../services/journey_suggestion.dart';
import '../state/journey_providers.dart';
import '../state/ride_providers.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/fill_or_scroll.dart';
import '../widgets/mini_rail.dart';
import '../widgets/pressable.dart';
import '../widgets/status_chip.dart';

/// Screen 1, Home. The screen a rider opens, and on a good day the only one
/// they touch: tap a destination, the ride starts.
///
/// STATES, keyed to journeys COMPLETED and never to routes saved (settled
/// 16 Jul 2026, when the owner caught the hole where a rider who never saves
/// anything would be stuck on an empty screen forever):
///
///   1. FIRST RUN, no journey has ever completed. The promise line and one
///      white CTA. WHITE SINCE 11 Aug 2026: it was crimson, on the old rule
///      that crimson meant start OR end. Crimson now means end a ride and
///      nothing else, so every control that leads to a ride starting is white.
///   2. JOURNEYS BUT NOTHING SAVED. Recent destinations fill the card slots,
///      so a non-saver keeps the two-tap start forever.
///   3. SAVED ROUTES EXIST. Not built: SavedRoute has no model, no table and
///      no way to be created yet. When it lands, saved cards go first and
///      recents fill the remaining slots, three cards total.
///
/// The network schematic the design notes propose for the dead space is
/// deliberately absent. Its only bright element was to be a position dot that
/// was deferred, and without the dot it is decoration; the notes' own kill
/// rule says the cards win. Add it if the dead space bothers a real rider.
/// Vertical padding on every tappable surface this screen owns.
///
/// TRIMMED FROM 20 ON 1 AUG 2026, after a first-time viewer read the screen as
/// "designed for senior citizens". The measurement backed them up rather than
/// the instinct that made it 20: the cards sat at about 65 dp and the CTA at
/// about 61, against a 48 to 56 dp convention for a full-width button.
///
/// WHAT WAS NOT TRIMMED MATTERS MORE. The wake alert stays at 30 (about 81 dp)
/// because it is pressed by someone asleep, and Screen 5's arrival buttons stay
/// because they are pressed on a moving train. The rule this file follows is to
/// size by the rider's STATE at the moment of the press, never for uniformity.
///
/// The floor is 48 dp, the touch-target minimum, and `home_screen_test` holds
/// it. These are still one-handed taps on a platform, so there is no room below
/// it however tidy a smaller number would look.
const _tapPadding = 16.0;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({
    super.key,
    required this.onStartTo,
    required this.onNew,
    this.onHistory,
    this.onSettings,
  });

  /// Start a ride to this destination. Origin is never picked here: it is
  /// detected live from GPS, which is why SavedRoute does not store one.
  final void Function(String destinationStationId) onStartTo;

  /// Open the destination picker (Screen 2).
  final VoidCallback onNew;

  /// Screen 7 and Screen 6, from the header row.
  ///
  /// Both nullable so this screen can still be pumped on its own in a test
  /// without inventing two destinations for it to navigate to.
  final VoidCallback? onHistory;
  final VoidCallback? onSettings;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_locateOnce());
  }

  /// Asks where the rider is, once, on arrival.
  ///
  /// Only when nobody has answered yet: another screen may already have a fix
  /// (today the debug screen does), and re-acquiring would throw away a good
  /// answer to ask the same question. The chip's tap is the retry.
  Future<void> _locateOnce() async {
    if (ref.read(nearestStationProvider).state != GpsState.locating) return;
    try {
      await ref.read(stationRepositoryProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await ref.read(nearestStationProvider.notifier).locate();
  }

  @override
  Widget build(BuildContext context) {
    final nearest = ref.watch(nearestStationProvider);
    final destinations = ref.watch(recentDestinationsProvider);
    // valueOrNull, not when(): saved routes are an ENHANCEMENT of the recent
    // list, so a database that will not answer this query must cost the rider
    // their saved cards and nothing else. The screen still works.
    final saved = ref.watch(savedRoutesProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          // Bottom-anchored: dead space goes at the top, actions in the thumb
          // zone. A locked layout rule, and it is why the spacer is here and
          // not between the cards. FillOrScroll keeps that layout exactly as it
          // is whenever there is room, and gives it somewhere to go when there
          // is not: with several saved routes and a raised font size the cards
          // ran 95 px past the bottom.
          child: FillOrScroll(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The chip and the two secondary destinations share one row.
                // Putting them on separate rows would spend two bands of vertical
                // space on things a rider touches rarely, and the whole layout is
                // built to keep the route cards in the thumb zone.
                Row(
                  children: [
                    // Expanded with an Align, NOT Flexible next to a Spacer. A
                    // Spacer takes a flex share, so it competed with the chip for
                    // the row and squeezed it until its own internal Row
                    // overflowed by 239 px. This gives the chip all the room that
                    // is left and lets it sit at its natural width on the left.
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: StatusChip(
                          state: nearest.state,
                          stationName: nearest.stationName,
                          onTap: () => unawaited(
                            ref.read(nearestStationProvider.notifier).locate(),
                          ),
                        ),
                      ),
                    ),
                    if (widget.onHistory != null)
                      _HeaderIcon(
                        // The design system's history glyph: the plain
                        // clock-with-counterclockwise-arrow, never a stopwatch,
                        // and no numeral (a "24" reads as open-24-hours).
                        icon: Icons.history,
                        tooltip: 'Journey history',
                        buttonKey: const Key('home_history'),
                        onTap: widget.onHistory!,
                      ),
                    if (widget.onSettings != null) ...[
                      const SizedBox(width: 4),
                      _HeaderIcon(
                        icon: Icons.settings_outlined,
                        tooltip: 'Settings',
                        buttonKey: const Key('home_settings'),
                        onTap: widget.onSettings!,
                      ),
                    ],
                  ],
                ),
                const Spacer(),
                destinations.when(
                  loading: () => const SizedBox.shrink(),
                  // History is a convenience, never the product. If the database
                  // will not answer, the rider can still start a journey.
                  error: (_, _) => _PrimaryCta(
                    buttonKey: const Key('new_journey'),
                    label: 'New journey',
                    onTap: widget.onNew,
                  ),
                  // STILL KEYED TO JOURNEYS COMPLETED, never to routes saved.
                  // A saved route cannot exist without a completed journey
                  // (Screen 5 is the only place one is created), so reading the
                  // saved list here would answer the same question less
                  // directly and reintroduce the 16 Jul hole if that ever
                  // changed.
                  data: (rides) => rides.isEmpty
                      ? _FirstRun(onStart: widget.onNew)
                      : _Cards(
                          saved: saved.valueOrNull ?? const [],
                          rides: rides,
                          // valueOrNull for the same reason as saved routes:
                          // this is an enhancement, and a query that will not
                          // answer must cost the rider one card, never the
                          // screen.
                          suggestion: ref
                              .watch(journeySuggestionProvider)
                              .valueOrNull,
                          onStartTo: widget.onStartTo,
                          onNew: widget.onNew,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet destination in the header row.
///
/// Deliberately dim and deliberately small. The emphasis rule is that the
/// loudest thing on a screen is its primary action, and on Screen 1 that is a
/// route card. These two are for the rare visit, not the daily one, so they get
/// a 44 pt target and almost no colour.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.tooltip,
    required this.buttonKey,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Key buttonKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Pressable(
        key: buttonKey,
        onTap: onTap,
        child: Padding(
          // 10 all round on a 22 icon gives a 42 pt target, which is the
          // minimum a thumb finds on a moving train.
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 22, color: Palette.textDim(0.6)),
        ),
      ),
    );
  }
}

/// State 1. No journey has ever completed, so there is nothing to list and
/// nothing to be clever about: say what the app does, and offer the one action.
class _FirstRun extends StatelessWidget {
  const _FirstRun({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MiniRail(stops: 5),
        const SizedBox(height: 28),
        Text(
          "Doze off. We'll wake you before your stop.",
          style: TextStyle(
            fontSize: TypeScale.display,
            letterSpacing: TypeScale.displayTracking,
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: Palette.text,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Save a route at the end of your first journey and it will be one '
          'tap from here.',
          style: TextStyle(
            fontSize: TypeScale.label,
            height: 1.4,
            color: Palette.textDim(0.55),
          ),
        ),
        const SizedBox(height: 28),
        _PrimaryCta(
          buttonKey: const Key('start_first_journey'),
          label: 'Start your first journey',
          onTap: onStart,
        ),
      ],
    );
  }
}

/// States 2 and 3, which are one list with a divider in it.
///
/// SAVED FIRST, THEN RECENTS, THREE CARDS TOTAL. Saved routes are the rider's
/// own answer to "where do I go", so they outrank a list the app inferred. The
/// cap is what keeps the cards in the thumb zone; past three the last card is
/// no longer reachable one-handed, which is the whole layout's reason for
/// being.
///
/// A DESTINATION IS NEVER OFFERED TWICE. Saving Kalyan as Home and then riding
/// there would otherwise put Kalyan on the screen as both "Home" and "Kalyan",
/// two cards that do exactly the same thing, and the rider would have to work
/// out whether they differ. They do not.
class _Cards extends StatelessWidget {
  const _Cards({
    required this.saved,
    required this.rides,
    required this.suggestion,
    required this.onStartTo,
    required this.onNew,
  });

  static const _slots = 3;

  final List<SavedRoute> saved;
  final List<JourneyRecord> rides;

  /// What the rider usually does from this platform at this hour, or null,
  /// which is the normal answer. See [JourneySuggester].
  final JourneySuggestion? suggestion;

  final void Function(String destinationStationId) onStartTo;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final suggestion = this.suggestion;
    // The suggested destination is REMOVED from the lists below rather than
    // shown twice. A rider looking at two cards for Dadar has to work out
    // whether they differ, on a platform, which is exactly the moment this
    // screen is supposed to be obvious.
    final suggestedId = suggestion?.destinationId;
    final shown = [
      for (final route in saved)
        if (route.destinationStationId != suggestedId) route,
    ].take(_slots).toList();
    final savedIds = {for (final route in shown) route.destinationStationId};
    final recents = [
      for (final ride in rides)
        if (!savedIds.contains(ride.destinationId) &&
            ride.destinationId != suggestedId)
          ride,
    ].take(_slots - shown.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (suggestion != null) ...[
          _DestinationCard(
            cardKey: const Key('suggestion_card'),
            // "Heading home?" ONLY when the destination is the route the rider
            // labelled Home. The app does not otherwise know which of a
            // person's stations is their house, and a confident wrong guess
            // about that is the kind of small wrongness that makes software
            // feel stupid.
            title: suggestion.isHome
                ? 'Heading home?'
                : 'Heading to ${suggestion.destinationName}?',
            // SAYS WHY, and the count is the point. A suggestion a rider can
            // check is one they can disagree with; one that just appears has
            // to be trusted, and this screen has not earned that.
            detail: suggestion.isHome
                ? '${suggestion.destinationName} - you usually do, around now'
                : 'You usually do, around now',
            onTap: () => onStartTo(suggestion.destinationId),
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 6),
        ],
        if (shown.isNotEmpty) ...[
          const _Eyebrow('Saved'),
          const SizedBox(height: 10),
          for (final route in shown) ...[
            _DestinationCard(
              cardKey: Key('saved_route_card_${route.label.toLowerCase()}'),
              // The LABEL leads, because that is the word the rider chose and
              // the one they recognise at a glance on a platform. The station
              // is underneath it, quiet, because it is the fact that has to be
              // checkable before a tap starts a ride.
              title: route.label,
              detail: route.destinationName,
              onTap: () => onStartTo(route.destinationStationId),
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (recents.isNotEmpty) ...[
          if (shown.isNotEmpty) const SizedBox(height: 6),
          const _Eyebrow('Recent'),
          const SizedBox(height: 10),
          for (final ride in recents) ...[
            _DestinationCard(
              cardKey: Key('destination_card_${ride.destinationId}'),
              title: ride.destinationName,
              onTap: () => onStartTo(ride.destinationId),
            ),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 6),
        _PrimaryCta(
          buttonKey: const Key('new_journey'),
          label: 'New journey',
          onTap: onNew,
        ),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: TypeScale.caption,
        letterSpacing: 0.4,
        color: Palette.textDim(0.45),
      ),
    );
  }
}

/// One tap starts the ride, so the whole card is the target and there is no
/// second control on it. Glass, not crimson: crimson fill is reserved for the
/// single action that starts or ends a journey, and with several cards on
/// screen none of them may claim it.
class _DestinationCard extends StatelessWidget {
  const _DestinationCard({
    required this.cardKey,
    required this.title,
    required this.onTap,
    this.detail,
  });

  final Key cardKey;
  final String title;

  /// The station under a saved route's label. Null on a recent card, where the
  /// title already IS the station.
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Pressable(
      key: cardKey,
      onTap: onTap,
      child: Container(
        decoration: Palette.glassCard(radius: 20),
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: _tapPadding,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: TypeScale.title,
                      fontWeight: FontWeight.w700,
                      color: Palette.text,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: TypeScale.label,
                        color: Palette.textDim(0.55),
                      ),
                    ),
                ],
              ),
            ),
            // Right chevron means launches. A down chevron is banned for
            // launch actions: it reads as an accordion.
            Icon(Icons.chevron_right, color: Palette.textDim(0.35), size: 26),
          ],
        ),
      ),
    );
  }
}

/// The primary action of Screen 1, in both of the screen's states.
///
/// ONE DEFINITION, closed 11 Aug 2026 (punchlist item 5). There were two:
/// "New journey" in white and "Start your first journey" in CRIMSON, and a
/// rider sees only one at a time, so it was never visible as an inconsistency.
/// It was one anyway. Both open the same picker, and by [Palette]'s own rule
/// crimson means start or end a JOURNEY, which opening a picker is not.
///
/// The white one won because it is the one that is right, not because it is the
/// newer: white means the primary action of the screen you are looking at, and
/// Screen 3's "Start the ride" has said so since it was built.
///
/// Typography follows the white button too, at [TypeScale.bodyLarge] and w600
/// rather than the crimson one's heading and w700. On the empty state there is
/// nothing to compete with, so the louder setting was free; making it the same
/// button in both states is worth more than the half-step of emphasis.
class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({
    required this.buttonKey,
    required this.label,
    required this.onTap,
  });

  /// On the [Pressable], not on this widget, and that is load bearing: the
  /// press-feedback test looks for a Pressable ANCESTOR of the key, which is
  /// how it proves the whole surface responds rather than some inner box.
  /// Same convention as [_HeaderIcon].
  final Key buttonKey;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      key: buttonKey,
      onTap: onTap,
      // WHITE, matching Screen 3's "Start the ride", because this is the
      // primary action of this screen and it was drawn as a route card.
      //
      // The saved and recent cards above are shortcuts: a rider who sees their
      // destination taps it and is done in two taps. This is what they press
      // when none of the above is right, which is a different KIND of thing,
      // and it was wearing the cards' own decoration (Palette.glassCard at
      // radius 18) with a dimmer label. Dim made it quieter without making it
      // different, so on a screen of three glass cards it read as a fourth.
      //
      // NO BORDER. A hairline exists to lift a near-invisible glass fill off
      // the ground; on an opaque white fill it would only muddy the edge.
      child: Container(
        decoration: BoxDecoration(
          color: Palette.accent,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Palette.shadow,
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: _tapPadding),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: TypeScale.bodyLarge,
              fontWeight: FontWeight.w600,
              color: Palette.onAccent,
            ),
          ),
        ),
      ),
    );
  }
}
