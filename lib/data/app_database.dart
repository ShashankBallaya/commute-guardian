import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

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

  /// Battery percentage when the ride started and when it ended.
  ///
  /// NULLABLE on purpose, two ways: rows written before schema 2 have none,
  /// and a platform that refuses the reading must not cost the rider their
  /// history row. The ride is the record; the battery is a note on it.
  ///
  /// This is the measurement Phase 3 needs to hold "a full Thane to Karjat
  /// ride costs under 8 to 10 percent" to account. It has been asked for on
  /// every ride sheet since 13 Jul and written down on none of them, because
  /// it depended on somebody remembering to look twice.
  IntColumn get batteryStartPct => integer().nullable()();
  IntColumn get batteryEndPct => integer().nullable()();
}

/// One route the rider saved, so Screen 1 can offer it as a card.
///
/// ORIGIN IS DELIBERATELY NOT STORED. A saved route is a destination and a
/// label; where the rider is starting from is detected live from GPS, because
/// the same "Home" means Dadar in the morning and Kalyan at night.
class SavedRoutes extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// What the rider calls it: "Home", "Work". Asked for at journey end, when
  /// the route has proven real.
  TextColumn get label => text()();
  TextColumn get destinationStationId => text()();
  TextColumn get destinationName => text()();
  DateTimeColumn get createdAt => dateTime()();
}

/// Small persistent facts that are not rides: has onboarding been seen, and
/// later whatever Settings needs.
///
/// Untyped key and value on purpose. Nothing in Settings is designed yet, so a
/// typed column per setting would be inventing a schema for screens that do
/// not exist. Callers own the parsing.
class AppFlags extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// The app's local store. Rides, saved routes and flags.
///
/// Named for the app rather than for history since 28 Jul 2026, when it grew
/// past rides. The JourneyRecords TABLE keeps its name for now: renaming a
/// table costs a migration, renaming a class does not, and the rows on the 3T
/// are real.
///
/// UI ISOLATE ONLY. The service isolate never opens this file.
@DriftDatabase(tables: [JourneyRecords, SavedRoutes, AppFlags])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// The on-device database, in the app documents directory next to the
  /// session logs.
  factory AppDatabase.open() {
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await getApplicationDocumentsDirectory();
        return NativeDatabase.createInBackground(
          File(p.join(dir.path, 'journey_history.sqlite')),
        );
      }),
    );
  }

  /// A throwaway in-memory database for tests.
  factory AppDatabase.inMemory() {
    return AppDatabase(NativeDatabase.memory());
  }

  @override
  int get schemaVersion => 3;

  /// Existing installs already hold rides (the 3T has recorded some), so the
  /// battery columns are ADDED to the live table rather than the database
  /// being recreated. Old rows keep null batteries, which is exactly what
  /// they know.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(journeyRecords, journeyRecords.batteryStartPct);
        await m.addColumn(journeyRecords, journeyRecords.batteryEndPct);
      }
      // Added together on 28 Jul 2026. Existing installs (the 3T holds
      // real rides) gain the tables without losing a row.
      if (from < 3) {
        await m.createTable(savedRoutes);
        await m.createTable(appFlags);
      }
    },
  );

  Future<void> record({
    required String originId,
    required String destinationId,
    required String originName,
    required String destinationName,
    required DateTime startedAt,
    required DateTime endedAt,
    required bool reachedDestination,
    required int stationCount,
    int? batteryStartPct,
    int? batteryEndPct,
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
        batteryStartPct: Value(batteryStartPct),
        batteryEndPct: Value(batteryEndPct),
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

  // -------------------------------------------------------------------------
  // Saved routes
  // -------------------------------------------------------------------------

  /// Newest first, which is the order Screen 1 shows them in.
  ///
  /// Ties break on id, because drift stores DateTime at SECOND resolution and
  /// two routes saved in the same second would otherwise come back in an
  /// undefined order. The autoincrementing id is the only monotonic thing here.
  Future<List<SavedRoute>> allSavedRoutes() {
    final query = select(savedRoutes)
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
    return query.get();
  }

  /// ONE ROUTE PER LABEL, so saving is also how a rider corrects one.
  ///
  /// Screen 5 offers exactly two names, Home and Work, and a rider whose Home
  /// moves has no other way to fix it: there is no edit screen and no delete
  /// gesture, by design (see Screen 1). Riding to the new one and tapping Home
  /// again replaces it, which is the behaviour anyone would expect from a slot
  /// with a name on it. It also caps free saved routes at two without a rule
  /// that has to be written down or enforced anywhere.
  Future<void> saveRoute({
    required String label,
    required String destinationStationId,
    required String destinationName,
  }) {
    return transaction(() async {
      await (delete(savedRoutes)..where((t) => t.label.equals(label))).go();
      await into(savedRoutes).insert(
        SavedRoutesCompanion.insert(
          label: label,
          destinationStationId: destinationStationId,
          destinationName: destinationName,
          createdAt: DateTime.now(),
        ),
      );
    });
  }

  Future<void> deleteSavedRoute(int id) =>
      (delete(savedRoutes)..where((t) => t.id.equals(id))).go();

  // -------------------------------------------------------------------------
  // Flags
  // -------------------------------------------------------------------------

  Future<String?> flag(String key) async {
    final row = await (select(
      appFlags,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setFlag(String key, String value) => into(
    appFlags,
  ).insertOnConflictUpdate(AppFlagsCompanion.insert(key: key, value: value));

  /// Whether onboarding has been completed. A REINSTALL WIPES THIS along with
  /// the permission grants it exists to explain, which is correct: a rider
  /// whose grants are gone needs walking through them again.
  static const onboardingSeenKey = 'onboarding_seen';

  Future<bool> hasSeenOnboarding() async =>
      (await flag(onboardingSeenKey)) == 'true';

  Future<void> markOnboardingSeen() => setFlag(onboardingSeenKey, 'true');
}
