import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:drift/backends.dart';
import 'package:drift/drift.dart' show OpeningDetails, QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Schema 3 to schema 4, the migration that adds the route's identity to a
/// history row.
///
/// WHY THIS IS A FILE AND NOT AN IN-MEMORY DATABASE. A migration can only be
/// tested against a database that already exists at the OLD version, and
/// `AppDatabase.inMemory()` is created at the current one. The 3T holds real
/// rides and they are Phase 3 evidence, so "the column was added and the rows
/// survived" is the thing worth proving, not the column's existence.
///
/// No `package:sqlite3` and no schema dumps: drift opens a raw executor at
/// version 3, which is what stamps `user_version`, and the v3 table is written
/// out by hand below. The hand-written SQL is the point of the test, because
/// it is the shape the rider's phone actually holds.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cg_migration');
    file = File('${dir.path}/journey_history.sqlite');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// One ride, recorded by a build that had never heard of a route picker.
  Future<void> writeSchema3Ride() async {
    final raw = NativeDatabase(file);
    await raw.ensureOpen(_SchemaThree());
    await raw.runCustom('''
      CREATE TABLE journey_records (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        origin_id TEXT NOT NULL,
        destination_id TEXT NOT NULL,
        origin_name TEXT NOT NULL,
        destination_name TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER NOT NULL,
        reached_destination INTEGER NOT NULL,
        station_count INTEGER NOT NULL,
        battery_start_pct INTEGER NULL,
        battery_end_pct INTEGER NULL
      )
    ''', const []);
    await raw.runCustom('''
      INSERT INTO journey_records (
        origin_id, destination_id, origin_name, destination_name,
        started_at, ended_at, reached_destination, station_count,
        battery_start_pct, battery_end_pct
      ) VALUES (
        'shahad', 'prabhadevi', 'Shahad', 'Prabhadevi',
        ${DateTime(2026, 9, 5, 9).millisecondsSinceEpoch ~/ 1000},
        ${DateTime(2026, 9, 5, 10, 20).millisecondsSinceEpoch ~/ 1000},
        1, 24, 84, 71
      )
    ''', const []);
    await raw.close();
  }

  test(
    'a schema 3 install keeps its rides and gains the route column',
    () async {
      await writeSchema3Ride();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final rides = await db.recent();

      // THE ROW SURVIVED. That is the whole test: row 80 on the 3T is the 5 Sep
      // Kalyan to Chembur ride, and no schema change is allowed to cost it.
      expect(rides, hasLength(1));
      expect(rides.single.destinationName, 'Prabhadevi');
      expect(rides.single.stationCount, 24);
      expect(rides.single.batteryStartPct, 84);

      // And it knows what it knows: nobody asked this rider which way she went,
      // so the row says nothing rather than guessing a corridor.
      expect(rides.single.viaLabel, isNull);

      // READ OFF THE TABLE, not off the row. A missing column comes back from
      // drift as a null field, so `viaLabel is null` above passes just as
      // happily against a migration that never ran. This is the assertion that
      // fails when the ALTER TABLE is dropped.
      final columns = await db
          .customSelect('PRAGMA table_info(journey_records)')
          .get();
      expect(columns.map((row) => row.data['name']), contains('via_label'));
    },
  );

  test('a ride recorded after the migration names its route', () async {
    await writeSchema3Ride();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.record(
      originId: 'ghansoli',
      destinationId: 'csmt',
      originName: 'Ghansoli',
      destinationName: 'CSMT',
      startedAt: DateTime(2026, 9, 12, 9),
      endedAt: DateTime(2026, 9, 12, 10),
      reachedDestination: true,
      stationCount: 20,
      viaLabel: 'via Thane',
    );

    final rides = await db.recent();
    expect(rides, hasLength(2));
    expect(rides.first.viaLabel, 'via Thane');
    expect(rides.last.viaLabel, isNull);
  });
}

/// A database user that only exists to stamp `user_version = 3` on a fresh
/// file. It runs no migration of its own: the v3 table is written out above.
class _SchemaThree extends QueryExecutorUser {
  @override
  int get schemaVersion => 3;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
