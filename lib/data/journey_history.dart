import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'journey_history.g.dart';

/// One completed (or abandoned) ride. Station NAMES are denormalized on
/// purpose: history must still render its rows even if the generated station
/// data changes underneath it.
class JourneyRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get originId => text()();
  TextColumn get destinationId => text()();
  TextColumn get originName => text()();
  TextColumn get destinationName => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();

  /// True only when the destination arrival announcement actually spoke,
  /// the same signal the turnaround gate trusts. An early End stays false.
  BoolColumn get reachedDestination => boolean()();

  /// Stations in the planned chain, overshoot pin excluded, so the row can
  /// say "8 stations" without replanning a route that may no longer exist.
  IntColumn get stationCount => integer()();
}

/// The journey history store. Phase 1 scope: record rides and list them,
/// newest first. Screen 1's recents and the time-of-day smart defaults
/// query this table in Phase 2.
@DriftDatabase(tables: [JourneyRecords])
class JourneyHistoryDatabase extends _$JourneyHistoryDatabase {
  JourneyHistoryDatabase(super.executor);

  /// The on-device database, in the app documents directory next to the
  /// session logs.
  factory JourneyHistoryDatabase.open() {
    return JourneyHistoryDatabase(
      LazyDatabase(() async {
        final dir = await getApplicationDocumentsDirectory();
        return NativeDatabase.createInBackground(
          File(p.join(dir.path, 'journey_history.sqlite')),
        );
      }),
    );
  }

  /// A throwaway in-memory database for tests.
  factory JourneyHistoryDatabase.inMemory() {
    return JourneyHistoryDatabase(NativeDatabase.memory());
  }

  @override
  int get schemaVersion => 1;

  Future<void> record({
    required String originId,
    required String destinationId,
    required String originName,
    required String destinationName,
    required DateTime startedAt,
    required DateTime endedAt,
    required bool reachedDestination,
    required int stationCount,
  }) {
    return into(journeyRecords).insert(
      JourneyRecordsCompanion.insert(
        originId: originId,
        destinationId: destinationId,
        originName: originName,
        destinationName: destinationName,
        startedAt: startedAt,
        endedAt: endedAt,
        reachedDestination: reachedDestination,
        stationCount: stationCount,
      ),
    );
  }

  /// Newest rides first.
  Future<List<JourneyRecord>> recent({int limit = 20}) {
    final query = select(journeyRecords)
      ..orderBy([(t) => OrderingTerm.desc(t.endedAt)])
      ..limit(limit);
    return query.get();
  }

  /// Distinct destinations by most recent ride, the feed for Screen 1's
  /// recent-destination cards. A destination the rider goes to daily appears
  /// once, not once per ride.
  Future<List<JourneyRecord>> recentDestinations({int limit = 3}) async {
    final rides = await recent(limit: 50);
    final seen = <String>{};
    final result = <JourneyRecord>[];
    for (final ride in rides) {
      if (seen.add(ride.destinationId)) {
        result.add(ride);
        if (result.length >= limit) break;
      }
    }
    return result;
  }
}
