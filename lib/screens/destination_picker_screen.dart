import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/station_repository.dart';
import '../models/station.dart';
import '../state/journey_providers.dart';
import '../state/ride_providers.dart';
import '../theme/palette.dart';

/// Screen 2, New journey. The DESTINATION picker, and only that.
///
/// Origin is never picked here: it is detected live from GPS, which is why
/// SavedRoute stores no origin. Approved 28 Jul 2026.
///
/// Two states, and the second one is the screen. The field autofocuses, so a
/// rider spends their time looking at results with the keyboard up, not at the
/// resting list.
///
///   RESTING, no query: recent destinations, then the stations on whichever
///   line the rider is standing on.
///   TYPING: matches only. "Recent" disappears the moment a query exists,
///   because only three or four rows fit above the keyboard and an eyebrow
///   saying "Recent" over rows that do not contain the query reads as a broken
///   filter.
///
/// Every row is a live trigger: a tap picks the destination and the caller
/// starts the ride. Nothing else tappable may live on a row, which is why the
/// save star was removed and why saving a route belongs at journey end.
class DestinationPickerScreen extends ConsumerStatefulWidget {
  const DestinationPickerScreen({super.key, required this.onPicked});

  final void Function(Station destination) onPicked;

  @override
  ConsumerState<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState
    extends ConsumerState<DestinationPickerScreen> {
  /// Per-screen ephemeral state, deliberately not a provider: losing it costs
  /// the rider one keystroke.
  final TextEditingController _field = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(stationRepositoryProvider).valueOrNull;
    final searching = _query.trim().isNotEmpty;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onBack: () => Navigator.of(context).maybePop()),
              const SizedBox(height: 18),
              _SearchField(
                controller: _field,
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 18),
              if (repo != null)
                Expanded(
                  child: searching
                      ? _Results(
                          stations: _matches(repo),
                          onPicked: widget.onPicked,
                        )
                      : _Resting(repo: repo, onPicked: widget.onPicked),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Station.matches is the one search rule: English, Hindi, Marathi and the
  /// railway code, case-insensitive SUBSTRING. Substring rather than prefix is
  /// deliberate and visible in results ("tha" finds Vithalwadi); fuzzy is not
  /// offered, so a typo finds nothing.
  ///
  /// Data order, not relevance-ranked. The approved mockup happens to show
  /// Kalyan above Kalwa, which would imply recency weighting; that is a real
  /// rule nobody has built, and ride history already knows the answer if it
  /// ever proves necessary.
  List<Station> _matches(StationRepository repo) {
    return [
      for (final station in repo.stationsById.values)
        if (station.matches(_query)) station,
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          key: const Key('picker_back'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: Icon(Icons.chevron_left, color: Palette.textDim(0.7), size: 30),
          onPressed: onBack,
        ),
        const SizedBox(width: 4),
        const Text(
          'New journey',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: Palette.text,
          ),
        ),
      ],
    );
  }
}

/// RAISED glass, not the recessed well the app's InputDecorationTheme gives
/// every other field. Decided in the 28 Jul review, and this is the only
/// screen that overrides it, so the override is explicit here rather than
/// changed globally.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          Icon(Icons.search, color: Palette.textDim(0.5), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('destination_search'),
              controller: controller,
              onChanged: onChanged,
              autofocus: true,
              cursorColor: Palette.dotGreen,
              style: const TextStyle(fontSize: 19, color: Palette.text),
              decoration: InputDecoration(
                // The screen only ever sets the destination, so the hint says
                // so. "Search station" never told the rider which end.
                hintText: 'Where to?',
                hintStyle: TextStyle(fontSize: 19, color: Palette.textDim(0.5)),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 18),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// No query yet: what the rider is most likely to want, then where they are.
class _Resting extends ConsumerWidget {
  const _Resting({required this.repo, required this.onPicked});

  final StationRepository repo;
  final void Function(Station) onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(recentDestinationsProvider).valueOrNull ?? const [];
    final originId = ref.watch(journeyDraftProvider).originId;
    final lines = _linesThrough(originId);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (recents.isNotEmpty) ...[
          _StationCard(
            eyebrow: 'Recent',
            stations: [
              for (final ride in recents)
                if (repo.stationsById[ride.destinationId] != null)
                  repo.stationsById[ride.destinationId]!,
            ],
            onPicked: onPicked,
          ),
          const SizedBox(height: 16),
        ],
        // The rider's own line, because most destinations are on it.
        for (final entry in lines.entries) ...[
          _StationCard(
            eyebrow: '${entry.key} line',
            stations: _alphabetical(entry.value),
            onPicked: onPicked,
          ),
          const SizedBox(height: 16),
        ],
        if (lines.isEmpty)
          _StationCard(
            eyebrow: 'All stations',
            stations: _alphabetical(repo.stationsById.keys.toList()),
            onPicked: onPicked,
          ),
      ],
    );
  }

  /// The lines through [stationId], MERGED BY SPOKEN NAME.
  ///
  /// Kalyan sits on three Line records (the trunk, Kasara and Karjat) and all
  /// three are called "Central", so one card per record would render three
  /// identical "Central line" eyebrows over overlapping lists. Grouping by
  /// shortName is also what the rider means: at Kalyan, "Central line" is
  /// everywhere Central can take them.
  Map<String, List<String>> _linesThrough(String? stationId) {
    if (stationId == null) return const {};
    final byName = <String, List<String>>{};
    for (final line in repo.linesById.values) {
      if (!line.stationIds.contains(stationId)) continue;
      byName.putIfAbsent(line.shortName, () => <String>[]).addAll(line.stationIds);
    }
    return byName;
  }

  List<Station> _alphabetical(List<String> ids) {
    // Deduped: merged branches share their trunk stations.
    final stations = [
      for (final id in ids.toSet())
        if (repo.stationsById[id] != null) repo.stationsById[id]!,
    ];
    stations.sort((a, b) => a.name.compareTo(b.name));
    return stations;
  }
}

/// A query exists: matches, and nothing else.
class _Results extends StatelessWidget {
  const _Results({required this.stations, required this.onPicked});

  final List<Station> stations;
  final void Function(Station) onPicked;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      // Substring, not fuzzy, so a typo genuinely finds nothing. Say that
      // plainly rather than showing an empty card.
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'No station by that name.',
          style: TextStyle(fontSize: 15, color: Palette.textDim(0.5)),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [_StationCard(stations: stations, onPicked: onPicked)],
    );
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({
    this.eyebrow,
    required this.stations,
    required this.onPicked,
  });

  final String? eyebrow;
  final List<Station> stations;
  final void Function(Station) onPicked;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow!,
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 0.4,
                color: Palette.textDim(0.45),
              ),
            ),
            const SizedBox(height: 6),
          ],
          for (final station in stations)
            _StationRow(station: station, onPicked: onPicked),
        ],
      ),
    );
  }
}

/// The whole row is the trigger and there is nothing else on it.
class _StationRow extends StatelessWidget {
  const _StationRow({required this.station, required this.onPicked});

  final Station station;
  final void Function(Station) onPicked;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('station_row_${station.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onPicked(station),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                station.name,
                style: const TextStyle(fontSize: 19, color: Palette.text),
              ),
            ),
            // The code is on the platform boards, and it is what separates
            // Dadar (DDR) from Dadar Western. Trailing slot, quiet.
            Text(
              station.code,
              style: TextStyle(
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: Palette.textDim(0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
