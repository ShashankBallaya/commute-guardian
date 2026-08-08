import 'package:commute_guardian/services/journey_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "Heading home?" suggestion.
///
/// Most of these tests are about it SAYING NOTHING. Screen 1 is two deliberate
/// taps to a ride the rider chose, and a wrong card at the top of it is one
/// mis-tap from the wrong ride on a crowded platform. A miss costs one tap; a
/// false suggestion costs trust in the screen.
void main() {
  const suggester = JourneySuggester();

  // Tuesday, 8am: the commute out.
  final tuesdayMorning = DateTime(2026, 8, 4, 8);

  PastRide ride(
    String origin,
    String destination,
    DateTime at, {
    String? name,
  }) => PastRide(
    originId: origin,
    destinationId: destination,
    destinationName: name ?? destination,
    startedAt: at,
  );

  /// The [count] weekdays before [now], skipping weekends.
  ///
  /// SKIPPING MATTERS. The first draft of this helper just stepped back one
  /// day at a time, so half its "commute" landed on a Saturday and a Sunday,
  /// the engine correctly threw those out, and every speaking test failed
  /// while every silent one passed. The fixture was wrong, not the engine.
  List<DateTime> weekdaysBefore(DateTime now, int count, int hour) {
    final days = <DateTime>[];
    var day = DateTime(now.year, now.month, now.day, hour);
    while (days.length < count) {
      day = day.subtract(const Duration(days: 1));
      if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
        continue;
      }
      days.add(day);
    }
    return days;
  }

  /// [count] rides Kalyan to Dadar, on the weekdays before [now].
  List<PastRide> commute(DateTime now, {int count = 4, int hour = 8}) => [
    for (final day in weekdaysBefore(now, count, hour))
      ride('kalyan', 'dadar', day, name: 'Dadar'),
  ];

  group('when it speaks', () {
    test('a real habit is suggested, and it says how it knows', () {
      final suggestion = suggester.suggest(
        history: commute(tuesdayMorning),
        atStationId: 'kalyan',
        now: tuesdayMorning,
      );

      expect(suggestion, isNotNull);
      expect(suggestion!.destinationId, 'dadar');
      expect(suggestion.destinationName, 'Dadar');
      // The count is shown to the rider. A suggestion that cannot be checked
      // is one that has to be trusted.
      expect(suggestion.matches, 4);
      expect(suggestion.isHome, isFalse);
    });

    test('only the saved Home route may be called home', () {
      // The app does not otherwise know which of a person's stations is their
      // house. The one place it does know is a route they labelled Home.
      final suggestion = suggester.suggest(
        history: commute(tuesdayMorning),
        atStationId: 'kalyan',
        now: tuesdayMorning,
        homeDestinationId: 'dadar',
      );
      expect(suggestion!.isHome, isTrue);
    });

    test('THE LAST TRAIN IS THE SAME COMMUTE AS ONE AFTER MIDNIGHT', () {
      // 23:40 and 00:30 are fifty minutes apart and would read as twenty three
      // hours to arithmetic that does not wrap. A rider on the last train is
      // exactly the rider this app is for.
      final lateNight = DateTime(2026, 8, 5, 0, 30);
      final history = [
        for (final day in weekdaysBefore(lateNight, 4, 23))
          ride('kalyan', 'dadar', day.add(const Duration(minutes: 40))),
      ];
      final suggestion = suggester.suggest(
        history: history,
        atStationId: 'kalyan',
        now: lateNight,
      );
      expect(suggestion, isNotNull);
    });
  });

  group('when it stays quiet, which is most of the time', () {
    test('a new rider is never guessed at', () {
      expect(
        suggester.suggest(
          history: const [],
          atStationId: 'kalyan',
          now: tuesdayMorning,
        ),
        isNull,
      );
    });

    test('two rides is a coincidence, not a habit', () {
      expect(
        suggester.suggest(
          history: commute(tuesdayMorning, count: 2),
          atStationId: 'kalyan',
          now: tuesdayMorning,
        ),
        isNull,
      );
    });

    test('IT REFUSES A COIN FLIP', () {
      // Three to Dadar and two to Thane from the same platform at the same
      // hour is not one habit, it is two. Picking the marginally more common
      // one would be a guess wearing evidence as a costume.
      final history = [
        ...commute(tuesdayMorning, count: 3),
        for (final day in weekdaysBefore(tuesdayMorning, 2, 8))
          ride('kalyan', 'thane', day),
      ];
      expect(
        suggester.suggest(
          history: history,
          atStationId: 'kalyan',
          now: tuesdayMorning,
        ),
        isNull,
      );
    });

    test('NO FIX MEANS NO SUGGESTION', () {
      // The whole context is where the rider is standing. Falling back to the
      // time of day alone is precisely the guess this design refuses.
      expect(
        suggester.suggest(
          history: commute(tuesdayMorning),
          atStationId: null,
          now: tuesdayMorning,
        ),
        isNull,
      );
    });

    test('a different platform is a different question', () {
      // The rider's Kalyan habit says nothing about what they do at Thane.
      expect(
        suggester.suggest(
          history: commute(tuesdayMorning),
          atStationId: 'thane',
          now: tuesdayMorning,
        ),
        isNull,
      );
    });

    test('the morning commute is not offered in the evening', () {
      final evening = DateTime(2026, 8, 4, 19);
      expect(
        suggester.suggest(
          history: commute(evening, hour: 8),
          atStationId: 'kalyan',
          now: evening,
        ),
        isNull,
      );
    });

    test('a weekday habit is not offered on a Sunday', () {
      // A Sunday trip to Kasara and a Tuesday commute to Dadar are different
      // journeys, and mixing them is how one starts suggesting the other.
      final sunday = DateTime(2026, 8, 9, 8);
      expect(
        suggester.suggest(
          history: commute(DateTime(2026, 8, 7, 8)),
          atStationId: 'kalyan',
          now: sunday,
        ),
        isNull,
      );
    });

    test('A COMMUTE THAT ENDED IN APRIL DOES NOT HAUNT AUGUST', () {
      // People move house and change jobs. An app that will not let them is
      // worse than one that never guessed.
      final old = [
        for (var i = 1; i <= 6; i++)
          ride('kalyan', 'dadar', DateTime(2026, 4, i + 6, 8)),
      ];
      expect(
        suggester.suggest(
          history: old,
          atStationId: 'kalyan',
          now: DateTime(2026, 8, 4, 8),
        ),
        isNull,
      );
    });

    test('it cannot suggest the station the rider is standing at', () {
      // "Heading home?" while at home is the version that makes an app look
      // ridiculous. History should never contain these, but the engine does
      // not rely on that.
      final history = [
        for (final day in weekdaysBefore(tuesdayMorning, 5, 8))
          ride('kalyan', 'kalyan', day),
      ];
      expect(
        suggester.suggest(
          history: history,
          atStationId: 'kalyan',
          now: tuesdayMorning,
        ),
        isNull,
      );
    });
  });
}
