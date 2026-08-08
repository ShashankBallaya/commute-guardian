/// One completed ride, reduced to the four facts a suggestion may reason from.
///
/// A deliberate narrowing of the history row. The engine cannot see how long
/// the ride took, which line it used, how many stations it passed or what the
/// battery did, because none of that should be able to influence a guess made
/// on a rider's behalf.
class PastRide {
  const PastRide({
    required this.originId,
    required this.destinationId,
    required this.destinationName,
    required this.startedAt,
  });

  final String originId;
  final String destinationId;
  final String destinationName;
  final DateTime startedAt;
}

/// What the app thinks the rider is about to do, and why it thinks so.
class JourneySuggestion {
  const JourneySuggestion({
    required this.destinationId,
    required this.destinationName,
    required this.matches,
    required this.isHome,
  });

  final String destinationId;
  final String destinationName;

  /// How many past rides support it. Shown to the rider, because a suggestion
  /// that cannot be checked is a suggestion that has to be trusted.
  final int matches;

  /// True when this destination is the route the rider labelled Home. ONLY
  /// then may anything say "home": the app does not otherwise know which of a
  /// person's stations is their house, and guessing it wrong is the kind of
  /// small wrongness that makes software feel stupid.
  final bool isHome;
}

/// The "Heading home?" suggestion (handover Phase 2), built as a RANKING over
/// the rider's own completed rides rather than as a prediction.
///
/// THE RISK THIS FEATURE CARRIES, and why it is shaped like this. Screen 1 is
/// two deliberate taps to a ride the rider chose. A card that guesses on their
/// behalf can be wrong, and a wrong guess at the top of that screen is worse
/// than no card at all: it is one mis-tap away from starting the wrong ride,
/// on the screen whose entire job is being unambiguous on a crowded platform.
///
/// So four rules, and they are all about staying quiet:
///
///   1. IT ONLY EVER REPEATS THE RIDER BACK TO THEMSELVES. Every candidate is
///      a destination they have already ridden to, from the station they are
///      standing at now. It cannot invent a journey.
///   2. IT NEEDS EVIDENCE, [minMatches] past rides in the same context, or it
///      says nothing. The same asymmetry the edge states use: a miss costs the
///      rider one tap, a false suggestion costs them trust in the screen.
///   3. IT REFUSES COIN FLIPS. A rider who goes two places from one station at
///      one hour does not have a habit there, and picking the marginally more
///      common one would be a guess wearing evidence as a costume.
///   4. IT NEVER DECIDES. This returns a suggestion; the caller draws a card
///      that behaves exactly like the others. Nothing here starts a ride.
///
/// It also cannot suggest the station the rider is standing at, which is the
/// obvious failure of a naive version: at 7pm at home, "heading home?" is the
/// question that makes an app look ridiculous.
class JourneySuggester {
  const JourneySuggester({
    this.minMatches = 3,
    this.margin = 2,
    this.hourWindow = 2,
    this.memory = const Duration(days: 60),
  });

  /// Past rides in this context before anything is said. Three, not two: two
  /// is a coincidence on a commute, and the cost of waiting is one tap.
  final int minMatches;

  /// How far ahead of the runner-up the winner must be. Below this the rider
  /// has two habits here, not one, and the screen should let them choose.
  final int margin;

  /// Hours either side of now that count as "this time of day". Two, because a
  /// Mumbai commuter's evening train varies by more than an hour and a window
  /// tighter than the variance would mean the habit never accumulates.
  final int hourWindow;

  /// How far back the engine remembers. A commute that changed in April must
  /// not keep suggesting itself in August: people move house and change jobs,
  /// and an app that will not let them is worse than one that never guessed.
  final Duration memory;

  /// The suggestion for a rider standing at [atStationId] at [now], or null.
  ///
  /// Null is the normal answer and the safe one. It means the screen shows
  /// exactly what it showed before this feature existed.
  JourneySuggestion? suggest({
    required List<PastRide> history,
    required String? atStationId,
    required DateTime now,
    String? homeDestinationId,
  }) {
    // No fix means no context. A suggestion keyed on where the rider is
    // cannot be made when that is exactly what is unknown, and inventing one
    // from the time of day alone would be the guess this design refuses.
    if (atStationId == null) return null;

    final counts = <String, int>{};
    final names = <String, String>{};
    for (final ride in history) {
      if (ride.originId != atStationId) continue;
      if (ride.destinationId == atStationId) continue;
      if (now.difference(ride.startedAt) > memory) continue;
      if (!_sameDayType(ride.startedAt, now)) continue;
      if (!_sameTimeOfDay(ride.startedAt, now)) continue;
      counts[ride.destinationId] = (counts[ride.destinationId] ?? 0) + 1;
      names[ride.destinationId] = ride.destinationName;
    }
    if (counts.isEmpty) return null;

    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = ranked.first;
    if (top.value < minMatches) return null;

    final runnerUp = ranked.length > 1 ? ranked[1].value : 0;
    if (top.value - runnerUp < margin) return null;

    return JourneySuggestion(
      destinationId: top.key,
      destinationName: names[top.key]!,
      matches: top.value,
      isHome: homeDestinationId != null && homeDestinationId == top.key,
    );
  }

  /// Weekday and weekend commutes are different journeys, and mixing them is
  /// how a Sunday trip to Kasara starts suggesting itself on a Tuesday.
  bool _sameDayType(DateTime a, DateTime b) => _isWeekend(a) == _isWeekend(b);

  static bool _isWeekend(DateTime t) =>
      t.weekday == DateTime.saturday || t.weekday == DateTime.sunday;

  /// Within [hourWindow] hours, WRAPPING AROUND MIDNIGHT. A rider on the 23:40
  /// last train and one at 00:30 are on the same commute, and arithmetic that
  /// treats them as twenty three hours apart would never learn it.
  bool _sameTimeOfDay(DateTime a, DateTime b) {
    final difference = (a.hour - b.hour).abs();
    return (difference <= hourWindow) || (24 - difference <= hourWindow);
  }
}
