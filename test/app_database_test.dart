import 'package:commute_guardian/data/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.inMemory());
  tearDown(() => db.close());

  Future<void> ride(
    String destinationId,
    String destinationName,
    DateTime endedAt, {
    bool reached = true,
  }) {
    return db.record(
      originId: 'shahad',
      destinationId: destinationId,
      originName: 'Shahad',
      destinationName: destinationName,
      startedAt: endedAt.subtract(const Duration(minutes: 40)),
      endedAt: endedAt,
      reachedDestination: reached,
      stationCount: 8,
    );
  }

  test('recent lists rides newest first', () async {
    await ride('kalyan', 'Kalyan', DateTime(2026, 7, 17, 9));
    await ride('thane', 'Thane', DateTime(2026, 7, 17, 19));

    final rides = await db.recent();

    expect(rides, hasLength(2));
    expect(rides.first.destinationName, 'Thane');
    expect(rides.last.destinationName, 'Kalyan');
  });

  test('an early End is recorded as not reaching the destination', () async {
    await ride('kalyan', 'Kalyan', DateTime(2026, 7, 17, 9), reached: false);

    final rides = await db.recent();

    expect(rides.single.reachedDestination, isFalse);
  });

  test('recentDestinations collapses repeat rides to the same place', () async {
    // A commuter's week: Thane every morning, Kalyan every evening, one
    // odd trip to CSMT. The cards should offer three places, not five rides.
    await ride('thane', 'Thane', DateTime(2026, 7, 13, 9));
    await ride('kalyan', 'Kalyan', DateTime(2026, 7, 13, 19));
    await ride('thane', 'Thane', DateTime(2026, 7, 14, 9));
    await ride('kalyan', 'Kalyan', DateTime(2026, 7, 14, 19));
    await ride('csmt', 'CSMT', DateTime(2026, 7, 15, 12));

    final destinations = await db.recentDestinations();

    expect(destinations.map((r) => r.destinationId).toList(), [
      'csmt',
      'kalyan',
      'thane',
    ]);
  });

  test('recent respects its limit', () async {
    for (var day = 1; day <= 25; day++) {
      await ride('kalyan', 'Kalyan', DateTime(2026, 7, day, 19));
    }

    expect(await db.recent(limit: 20), hasLength(20));
  });

  test('a ride records the battery it started and ended on', () async {
    // The cost of a ride has been guessed at since the 13 Jul thermal report
    // and asked for on every ride sheet since; nobody ever wrote the numbers
    // down. Storing them per ride is what makes Phase 3's "under 8 to 10
    // percent for a full Thane to Karjat run" measurable instead of folklore.
    await db.record(
      originId: 'thane',
      destinationId: 'kalyan',
      originName: 'Thane',
      destinationName: 'Kalyan',
      startedAt: DateTime(2026, 7, 20, 9),
      endedAt: DateTime(2026, 7, 20, 10),
      reachedDestination: true,
      stationCount: 8,
      batteryStartPct: 84,
      batteryEndPct: 71,
    );

    final row = (await db.recent()).single;
    expect(row.batteryStartPct, 84);
    expect(row.batteryEndPct, 71);
  });

  test('a ride whose battery could not be read still records', () async {
    // A platform that refuses the reading must never cost the rider their
    // history row: the ride is the record, the battery is a note on it.
    await ride('kalyan', 'Kalyan', DateTime(2026, 7, 20, 19));

    final row = (await db.recent()).single;
    expect(row.batteryStartPct, isNull);
    expect(row.batteryEndPct, isNull);
  });

  group('saved routes', () {
    test(
      'a saved route keeps a label and a destination, and no origin',
      () async {
        await db.saveRoute(
          label: 'Home',
          destinationStationId: 'kalyan',
          destinationName: 'Kalyan',
        );

        final routes = await db.allSavedRoutes();
        expect(routes, hasLength(1));
        expect(routes.single.label, 'Home');
        expect(routes.single.destinationStationId, 'kalyan');
        // There is deliberately no origin column: the same "Home" starts from
        // Dadar in the morning and Kalyan at night, so origin is detected live.
        expect(routes.single.toJson().keys, isNot(contains('originStationId')));
      },
    );

    test('newest first, which is the order Screen 1 shows them in', () async {
      await db.saveRoute(
        label: 'Home',
        destinationStationId: 'kalyan',
        destinationName: 'Kalyan',
      );
      await db.saveRoute(
        label: 'Work',
        destinationStationId: 'csmt',
        destinationName: 'CSMT',
      );

      expect((await db.allSavedRoutes()).map((r) => r.label), ['Work', 'Home']);
    });

    test(
      'SAVING A LABEL AGAIN REPLACES IT, it does not add a second',
      () async {
        // Screen 5 offers exactly two names, and there is no edit screen and no
        // delete gesture, so this is the only way a rider whose Home moves can
        // ever correct it: ride to the new one and tap Home again.
        await db.saveRoute(
          label: 'Home',
          destinationStationId: 'kalyan',
          destinationName: 'Kalyan',
        );
        await db.saveRoute(
          label: 'Home',
          destinationStationId: 'shahad',
          destinationName: 'Shahad',
        );

        final routes = await db.allSavedRoutes();
        expect(routes, hasLength(1));
        expect(routes.single.destinationStationId, 'shahad');
        // And it does not disturb the other slot.
        await db.saveRoute(
          label: 'Work',
          destinationStationId: 'csmt',
          destinationName: 'CSMT',
        );
        expect((await db.allSavedRoutes()).map((r) => r.label), [
          'Work',
          'Home',
        ]);
      },
    );

    test('a route can be removed', () async {
      await db.saveRoute(
        label: 'Home',
        destinationStationId: 'kalyan',
        destinationName: 'Kalyan',
      );

      await db.deleteSavedRoute((await db.allSavedRoutes()).single.id);
      expect(await db.allSavedRoutes(), isEmpty);
    });
  });

  group('flags', () {
    test('onboarding starts unseen and can be marked', () async {
      expect(await db.hasSeenOnboarding(), isFalse);
      await db.markOnboardingSeen();
      expect(await db.hasSeenOnboarding(), isTrue);
    });

    test('setting the same flag twice updates rather than throwing', () async {
      await db.setFlag('pulse_interval', '90');
      await db.setFlag('pulse_interval', '120');

      expect(await db.flag('pulse_interval'), '120');
    });

    test('an unset flag is null, not an error', () async {
      expect(await db.flag('nothing_set_this'), isNull);
    });
  });
}
