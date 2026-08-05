import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../state/ride_providers.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';

/// Screen 7, History. Every ride this phone has recorded, newest first.
///
/// A RECORD, NOT A SHORTCUT. The rows carry no fill, because in this design
/// system a filled surface promises a tap, and nothing here takes one. That
/// was settled in the 28 Jul review by removing the fill rather than adding a
/// destination; "tap to ride it again" remains the obvious upgrade if history
/// ever needs to be somewhere riders go rather than somewhere they look.
///
/// The metadata is deliberately the honest set: how long, how many stations,
/// and WHETHER THE RIDE GOT THERE. That last one is the only field that says
/// whether the app did its job, which is why it survived the cut that dropped
/// the battery readings (those are a bench instrument, not a rider's record).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rides = ref.watch(rideHistoryProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('history_back'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    icon: Icon(
                      Icons.chevron_left,
                      color: Palette.textDim(0.7),
                      size: 30,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'History',
                    style: TextStyle(
                      fontSize: TypeScale.heading,
                      fontWeight: FontWeight.w600,
                      color: Palette.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: rides.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => _Empty(
                    message: 'Your journeys could not be read just now.',
                  ),
                  data: (list) => list.isEmpty
                      ? const _Empty(
                          message:
                              'No journeys yet. Ride one and it will appear here.',
                        )
                      // A list starts at the top. The bottom-anchored rule is
                      // about where ACTIONS go, and there are none here.
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: list.length,
                          itemBuilder: (context, i) => _RideRow(ride: list[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Text(
        message,
        style: TextStyle(
          fontSize: TypeScale.label,
          color: Palette.textDim(0.55),
        ),
      ),
    );
  }
}

class _RideRow extends StatelessWidget {
  const _RideRow({required this.ride});

  final JourneyRecord ride;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: ride.originName),
                      // Arrow, never a dash: the project's copy rule bans
                      // dash-as-separator everywhere, UI included.
                      TextSpan(
                        text: '  →  ',
                        style: TextStyle(color: Palette.textDim(0.5)),
                      ),
                      TextSpan(text: ride.destinationName),
                    ],
                  ),
                  style: const TextStyle(
                    fontSize: TypeScale.bodyLarge,
                    fontWeight: FontWeight.w700,
                    color: Palette.text,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // The scannable number, right-aligned so a column of rides can
              // be read down rather than across.
              Text(
                durationLabel(ride.startedAt, ride.endedAt),
                style: TextStyle(
                  fontSize: TypeScale.label,
                  color: Palette.textDim(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: metaLine(ride)),
                // The outcome LEAVES THE BULLET RUN on purpose. Seen stacked
                // seven deep on a real phone, it read as a fourth equal fact
                // in the dimmest text on the screen, which inverts the
                // hierarchy: this is the only field that says whether the app
                // did its job. A gap separates it from the homogeneous facts,
                // and only the EXCEPTION is brightened. A reached ride stays
                // quiet, because a rider scanning for the ride that went wrong
                // should not have to read past the ones that went right.
                const TextSpan(text: '   '),
                TextSpan(
                  text: outcomeLabel(ride),
                  style: TextStyle(
                    color: Palette.textDim(
                      ride.reachedDestination ? 0.45 : 0.7,
                    ),
                  ),
                ),
              ],
            ),
            style: TextStyle(
              fontSize: TypeScale.caption,
              color: Palette.textDim(0.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// "4 min", or "1 h 12 min" once a ride runs past the hour, which the Kasara
/// and Karjat legs do comfortably.
///
/// Anything under a minute is NAMED rather than floored. `inMinutes` truncates,
/// so a bench run or a journey the rider cancels on the platform used to render
/// as "0 min", which reads on a real screen as a field that failed to load
/// rather than as a very short ride.
String durationLabel(DateTime startedAt, DateTime endedAt) {
  final minutes = endedAt.difference(startedAt).inMinutes;
  if (minutes == 0) return 'under a minute';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

/// "Thu 23 Jul • 14:55 • 2 stations". The outcome is NOT part of this; it is
/// rendered separately by [_RideRow] so it can carry its own emphasis. See
/// [outcomeLabel].
///
/// Bullet separators and no dashes, per the copy rule. The time is when the
/// ride ENDED, which is what the debug sheet has always shown and what the
/// approved frame's numbers were taken from.
String metaLine(JourneyRecord ride) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final t = ride.endedAt;
  final day = days[t.weekday - 1];
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final stations = ride.stationCount == 1
      ? '1 station'
      : '${ride.stationCount} stations';
  return '$day ${t.day} ${months[t.month - 1]} • $hh:$mm • $stations';
}

/// Whether the ride got there. Kept as its own function because it is the only
/// field on this screen that judges the app rather than describing the ride.
String outcomeLabel(JourneyRecord ride) =>
    ride.reachedDestination ? 'reached' : 'ended early';
