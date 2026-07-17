import 'package:commute_guardian/data/journey_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late JourneyHistoryDatabase db;

  setUp(() => db = JourneyHistoryDatabase.inMemory());
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
}
