import 'journey.dart';
import 'station.dart';

/// One way of making a journey, with the facts a rider chooses on.
///
/// C7c. ADR 0004 turned the planner from the thing that DECIDES into the thing
/// that ENUMERATES, and this is what it enumerates. A [Journey] alone is not
/// enough to choose between: it carries the chain, the interchanges and the
/// platforms, which is everything the RIDE needs and none of what the DECISION
/// needs.
///
/// THE MISSING FACT WAS FREQUENCY, and it was being computed and thrown away.
/// `JourneyPlanner._planFor` already returns the set of lines a route uses, and
/// `planAlternatives` used to discard it and answer with bare journeys. So the
/// one label ADR 0004 names in full ("`via Diva, 12 stops, 1 change, hourly`
/// beside `via Dadar, 38 stops, 1 change, every few minutes`") was the one
/// thing the picker could not have said. The planner's own comment had already
/// promised it: "[Line.lowFrequency] is what the picker labels the result
/// with."
///
/// WHY THIS IS NOT A SECOND GENERATOR. The alternative was a second method that
/// re-derived labels beside `planAlternatives`, and the planner has already
/// paid for that mistake once: a second alternatives generator was written,
/// then deleted, because "two generators where one will do is a second thing to
/// keep true". So the one search answers with the one type, and there is
/// nowhere for a label to drift from its route.
class RouteOption {
  const RouteOption({
    required this.journey,
    required this.via,
    required this.lowFrequency,
  });

  final Journey journey;

  /// The interchange stations, in travel order. EMPTY MEANS A DIRECT RIDE.
  ///
  /// Stations rather than ids, because the only caller is a picker that has to
  /// print them, and the planner is the half of the app that already holds the
  /// station table. Handing the UI ids would make every screen that shows a
  /// route go and look them up again.
  final List<Station> via;

  /// Any line on this route runs roughly hourly (the Diva MEMUs).
  ///
  /// A LABEL, NEVER A FILTER, which is the whole of ADR 0004's defect B. The
  /// Vasai MEMU was not ranked and rejected, it was never searched, and the
  /// planner's comment calling an hourly train "not a route anyone would
  /// choose" was a preference judgement wearing a reality filter's clothes.
  /// The owner takes that MEMU by choice. So this word goes on the card and
  /// the rider decides what it is worth.
  final bool lowFrequency;

  /// Stations still to come after the origin. The number a rider counts down.
  ///
  /// Matches what the ride itself says on the lock screen ("3 stops to go") and
  /// on Screen 4, deliberately: a picker that measured a route one way and the
  /// ride that measured it another would be two numbers for one journey.
  int get stops => journey.chain.length - 1;

  int get changes => journey.interchanges.length;

  /// How a Mumbai rider says this route, and how she said it: through Vashi,
  /// through Thane. NULL FOR A DIRECT RIDE.
  ///
  /// ONE SPELLING, TWO PRESENTATIONS. The picker card and the commit window
  /// both name the route, and a card reading "via Thane and Dadar" over a
  /// window reading "via Dadar" would be one ride named two ways in three
  /// seconds. Null rather than "Direct" because the two callers want different
  /// words for that case: the card has room to say "Direct, no change", and the
  /// window, which has three seconds, says nothing at all. A ride with no
  /// change has no "which way" to answer.
  ///
  /// NEVER KILOMETRES. m-Indicator shows them and they are the least useful
  /// number here: 41 km on an hourly MEMU and 41 km of fast local are not the
  /// same commute.
  String? get viaLabel =>
      viaLabelFrom([for (final station in via) station.name]);

  /// Stops, changes, and frequency ONLY WHEN IT IS UNUSUAL.
  ///
  /// "Every few minutes" is the Mumbai default, and printing it on three cards
  /// out of four would turn the one card that says hourly into a word the eye
  /// has already learned to skip. Absence is the label for normal.
  ///
  /// A DEVIATION FROM ADR 0004, which writes the row out in full as "via Diva,
  /// 12 stops, 1 change, hourly beside via Dadar, 38 stops, 1 change, every few
  /// minutes". Raised by review as an owner call rather than a code fix.
  ///
  /// It lives on the model, beside [viaLabel], because a card that computed it
  /// from these three fields would be reaching into this object for everything
  /// it says and owning none of it.
  String get factsLine => [
    '$stops stops',
    switch (changes) {
      0 => 'no change',
      1 => '1 change',
      final count => '$count changes',
    },
    if (lowFrequency) 'about hourly',
  ].join('  ·  ');

  /// True when this is the route those ids name.
  ///
  /// THE CHAIN IS THE KEY BECAUSE IT IS EXACT, the same reasoning
  /// `JourneyPlanner.planAlong` is built on: alternatives are generated by
  /// banning a LINE rather than a change station, so two routes can change at
  /// the same place and still be different rides. Comparing anything smaller
  /// than the chain would mark the wrong card.
  bool isChain(List<String> ids) {
    if (ids.length != journey.chain.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != journey.chain[i].id) return false;
    }
    return true;
  }

  /// The key that makes the pick survive an OS kill. See
  /// `JourneyPlanner.planAlong`, which takes exactly this list back.
  List<String> get chainIds => [
    for (final station in journey.chain) station.id,
  ];
}

/// The ONE spelling of "via", for every screen that names a route.
///
/// Top-level rather than a method because the HISTORY ROW names a route too
/// and it has no [RouteOption]: it replans a finished ride from stored ids and
/// holds a bare [Journey]. A second join written over there would be one
/// sentence in two files, and the first change to the wording would leave the
/// picker saying "via Thane and Dadar" over a row saying "via Thane, Dadar".
///
/// NULL FOR A DIRECT RIDE, for the reason [RouteOption.viaLabel] gives: the
/// callers want different words for that case, and one of them wants none.
String? viaLabelFrom(List<String> interchangeNames) {
  if (interchangeNames.isEmpty) return null;
  if (interchangeNames.length == 1) return 'via ${interchangeNames.single}';
  final head = interchangeNames
      .sublist(0, interchangeNames.length - 1)
      .join(', ');
  return 'via $head and ${interchangeNames.last}';
}
