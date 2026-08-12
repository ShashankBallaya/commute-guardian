import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
///
/// TRIMMED AGAIN ON 12 AUG 2026, from 16 to 12.5, so the cards land at 51.3 dp
/// and match the CTA. Owner's call, and it is the second of the two ways to
/// make them agree: the first put the button UP to 58.3, and he preferred the
/// whole stack tighter.
///
/// **This leaves 3.3 dp above the floor.** That is the smallest headroom this
/// screen has ever had, and it is the number to look at before any future trim:
/// there is not another one available here.
const _cardPadding = 12.5;

/// The primary CTA's vertical padding, and it differs from [_cardPadding] on
/// purpose: the two numbers exist so the two HEIGHTS can be equal.
///
/// The card and the button are peers in one stack, and they were 58.3 dp and
/// 51.3 dp, measured off the device on 12 Aug 2026 when the owner said the
/// cards looked bigger. They were. Nobody had decided that: both used one
/// padding constant, and the whole 7 dp came from the card's title being
/// [TypeScale.title] at w700 while the button's label is [TypeScale.bodyLarge]
/// at w600, a type choice made for a different reason on 11 Aug.
///
/// Seven dp is below the threshold where a size difference reads as hierarchy.
/// It reads as sloppiness instead, which is worse than either being deliberate,
/// so the heights are equal now at 51.3 dp and `home_screen_test` holds them
/// equal. That test is the real guard: change either type size and it fails,
/// which forces the next person to decide this rather than inherit it.
///
/// COLOUR still carries the difference, and that is the intended split. The
/// white fill says "the path that always works"; the cards say "the ride you
/// probably want". They are the same size because they are the same kind of
/// thing to a thumb.
const _ctaPadding = 16.0;

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
                        label: 'Journey history',
                        buttonKey: const Key('home_history'),
                        onTap: widget.onHistory!,
                      ),
                    if (widget.onSettings != null) ...[
                      const SizedBox(width: 4),
                      _HeaderIcon(
                        icon: Icons.settings_outlined,
                        label: 'Settings',
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
/// Deliberately dim, and NOT deliberately small. The emphasis rule is that the
/// loudest thing on a screen belongs to going somewhere, and neither of these
/// does: one opens a log and one opens preferences. So they carry almost no
/// colour. Quiet is a colour decision; it was never a licence to go under the
/// touch floor.
///
/// This block used to say "the primary action is a route card", which
/// contradicted [_PrimaryCta] saying white means the primary action of the
/// screen. Two claims, and the screen followed both: the cards took the size
/// and the button took the colour, which is how they ended up 7 dp apart by
/// accident. See [_ctaPadding] for the resolution.
///
/// THEY WERE 42 dp UNTIL 12 AUG 2026, measured, and the floor is 48. The
/// screen's own touch-minimum test held the chip, the cards and the CTA and
/// never listed these, so the one rule this project states as accessibility
/// rather than taste was broken in the only two places the test could not see.
/// Both are in that test now.
///
/// The doc said 44 and the padding comment said 42 and the device said 42.
/// Three numbers for one control is how a floor gets crossed without anyone
/// deciding to cross it.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.label,
    required this.buttonKey,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Key buttonKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // SEMANTICS, NOT A Tooltip. A tooltip needs a hover or a long press, so on
    // a phone it is unreachable in ordinary use, and when it does fire it draws
    // a stock Material popup: the same Material bleed removed from the ripple
    // and the switch today. A label serves the screen reader, which is who the
    // tooltip was actually helping.
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        key: buttonKey,
        onTap: onTap,
        child: Padding(
          // 13 all round on a 22 icon is 48 dp exactly, the floor.
          padding: const EdgeInsets.all(13),
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
          _EnterOnce(
            key: const ValueKey('enter_suggestion'),
            index: 0,
            child: _DestinationCard(
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
          ),
          // 16, as one value. It was `SizedBox(10)` followed by
          // `SizedBox(6)`, which is a slip rather than a decision: every
          // spacing number on this screen should be one somebody can defend.
          const SizedBox(height: 16),
        ],
        if (shown.isNotEmpty) ...[
          const _Eyebrow('Saved'),
          const SizedBox(height: 10),
          for (final (i, route) in shown.indexed) ...[
            _EnterOnce(
              key: ValueKey('enter_saved_${route.label.toLowerCase()}'),
              index: i + 1,
              child: _DestinationCard(
              cardKey: Key('saved_route_card_${route.label.toLowerCase()}'),
              // The LABEL leads, because that is the word the rider chose and
              // the one they recognise at a glance on a platform. The station
              // is underneath it, quiet, because it is the fact that has to be
              // checkable before a tap starts a ride.
              title: route.label,
              detail: route.destinationName,
              onTap: () => onStartTo(route.destinationStationId),
            ),
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (recents.isNotEmpty) ...[
          if (shown.isNotEmpty) const SizedBox(height: 6),
          const _Eyebrow('Recent'),
          const SizedBox(height: 10),
          for (final (i, ride) in recents.indexed) ...[
            _EnterOnce(
              key: ValueKey('enter_recent_${ride.destinationId}'),
              index: shown.length + i + 1,
              child: _DestinationCard(
                cardKey: Key('destination_card_${ride.destinationId}'),
                title: ride.destinationName,
                onTap: () => onStartTo(ride.destinationId),
              ),
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

/// Fades and rises once, the first time it is built.
///
/// The cards used to POP IN. `recentDestinationsProvider` answers from the
/// database a frame or two after the screen opens, so every cold start showed
/// an empty screen and then an abruptly full one, with nothing in between.
///
/// STAGGERED, WHICH SCREEN 4 IS NOT ALLOWED TO BE, and the difference is the
/// point: a stagger is an ENTRANCE effect, this list genuinely enters once per
/// app open, and Screen 1 is a screen the rider passes through rather than one
/// held in a pocket for 45 minutes. The battery rule that forbids motion on
/// Screen 4 does not reach here.
///
/// It runs ONCE per card, not on every rebuild. The key is derived from the
/// card it wraps, so the State survives the rebuilds that a GPS fix or a
/// database answer cause, and a chip going green does not re-animate the list.
class _EnterOnce extends StatefulWidget {
  const _EnterOnce({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_EnterOnce> createState() => _EnterOnceState();
}

class _EnterOnceState extends State<_EnterOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    // 40 ms apart, inside the 30 to 80 band. Longer and the list feels slow to
    // arrive, which on the screen that exists to be two taps is the one thing
    // it may not feel.
    Future.delayed(Duration(milliseconds: 40 * widget.index), () {
      if (mounted) _in.forward();
    });
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion keeps the FADE and drops the RISE. Opacity is not the
    // category that causes motion sickness; translation is.
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) return widget.child;

    return AnimatedBuilder(
      animation: _in,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_in.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
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
      // A HAPTIC ON THE MOST MEANINGFUL COMMIT IN THE APP, and until 12 Aug 2026
      // there was none: a crowd-mode toggle in Settings ticked and starting a
      // journey did not. Utility says spend haptics on moments that matter, and
      // this tap hands the rider's stop to their pocket.
      //
      // `selectionClick`, the system tick, for the same reason PulseSwitch uses
      // it: this app's own buzzes MEAN things, and a UI control may not speak
      // the vocabulary that the wake alarm and Pocket Pulse own.
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        onTap();
      },
      child: Container(
        decoration: Palette.glassCard(radius: 20),
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: _cardPadding,
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
        padding: const EdgeInsets.symmetric(vertical: _ctaPadding),
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
