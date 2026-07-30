import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../state/journey_providers.dart';
import '../state/ride_providers.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
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
///      crimson CTA. Crimson is legitimate here: it starts a journey.
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

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          // Bottom-anchored: dead space goes at the top, actions in the thumb
          // zone. A locked layout rule, and it is why the spacer is here and
          // not between the cards.
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
                error: (_, _) => _NewJourneyButton(onTap: widget.onNew),
                data: (rides) => rides.isEmpty
                    ? _FirstRun(onStart: widget.onNew)
                    : _Recents(
                        rides: rides,
                        onStartTo: widget.onStartTo,
                        onNew: widget.onNew,
                      ),
              ),
            ],
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
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: Palette.text,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Save a route at the end of your first journey and it will be one '
          'tap from here.',
          style: TextStyle(fontSize: TypeScale.label, height: 1.4, color: Palette.textDim(0.55)),
        ),
        const SizedBox(height: 28),
        _CrimsonCta(
          key: const Key('start_first_journey'),
          label: 'Start your first journey',
          onTap: onStart,
        ),
      ],
    );
  }
}

/// State 2. Destinations the rider has actually ridden to, newest first.
class _Recents extends StatelessWidget {
  const _Recents({
    required this.rides,
    required this.onStartTo,
    required this.onNew,
  });

  final List<JourneyRecord> rides;
  final void Function(String destinationStationId) onStartTo;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recent',
          style: TextStyle(
            fontSize: TypeScale.caption,
            letterSpacing: 0.4,
            color: Palette.textDim(0.45),
          ),
        ),
        const SizedBox(height: 10),
        for (final ride in rides) ...[
          _DestinationCard(
            ride: ride,
            onTap: () => onStartTo(ride.destinationId),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        _NewJourneyButton(onTap: onNew),
      ],
    );
  }
}

/// One tap starts the ride, so the whole card is the target and there is no
/// second control on it. Glass, not crimson: crimson fill is reserved for the
/// single action that starts or ends a journey, and with several cards on
/// screen none of them may claim it.
class _DestinationCard extends StatelessWidget {
  const _DestinationCard({required this.ride, required this.onTap});

  final JourneyRecord ride;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      key: Key('destination_card_${ride.destinationId}'),
      onTap: onTap,
      child: Container(
        decoration: Palette.glassCard(radius: 20),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ride.destinationName,
                style: const TextStyle(
                  fontSize: TypeScale.title,
                  fontWeight: FontWeight.w700,
                  color: Palette.text,
                ),
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

class _NewJourneyButton extends StatelessWidget {
  const _NewJourneyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      key: const Key('new_journey'),
      onTap: onTap,
      child: Container(
        decoration: Palette.glassCard(radius: 18),
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            'New journey',
            style: TextStyle(
              fontSize: TypeScale.bodyLarge,
              fontWeight: FontWeight.w600,
              color: Palette.textDim(0.85),
            ),
          ),
        ),
      ),
    );
  }
}

class _CrimsonCta extends StatelessWidget {
  const _CrimsonCta({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Palette.crimson,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
        ),
      ),
    );
  }
}
