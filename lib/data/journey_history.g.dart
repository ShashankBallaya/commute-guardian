// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'journey_history.dart';

// ignore_for_file: type=lint
class $JourneyRecordsTable extends JourneyRecords
    with TableInfo<$JourneyRecordsTable, JourneyRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JourneyRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _originIdMeta = const VerificationMeta(
    'originId',
  );
  @override
  late final GeneratedColumn<String> originId = GeneratedColumn<String>(
    'origin_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _destinationIdMeta = const VerificationMeta(
    'destinationId',
  );
  @override
  late final GeneratedColumn<String> destinationId = GeneratedColumn<String>(
    'destination_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originNameMeta = const VerificationMeta(
    'originName',
  );
  @override
  late final GeneratedColumn<String> originName = GeneratedColumn<String>(
    'origin_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _destinationNameMeta = const VerificationMeta(
    'destinationName',
  );
  @override
  late final GeneratedColumn<String> destinationName = GeneratedColumn<String>(
    'destination_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<DateTime> endedAt = GeneratedColumn<DateTime>(
    'ended_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reachedDestinationMeta =
      const VerificationMeta('reachedDestination');
  @override
  late final GeneratedColumn<bool> reachedDestination = GeneratedColumn<bool>(
    'reached_destination',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("reached_destination" IN (0, 1))',
    ),
  );
  static const VerificationMeta _stationCountMeta = const VerificationMeta(
    'stationCount',
  );
  @override
  late final GeneratedColumn<int> stationCount = GeneratedColumn<int>(
    'station_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    originId,
    destinationId,
    originName,
    destinationName,
    startedAt,
    endedAt,
    reachedDestination,
    stationCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journey_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<JourneyRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('origin_id')) {
      context.handle(
        _originIdMeta,
        originId.isAcceptableOrUnknown(data['origin_id']!, _originIdMeta),
      );
    } else if (isInserting) {
      context.missing(_originIdMeta);
    }
    if (data.containsKey('destination_id')) {
      context.handle(
        _destinationIdMeta,
        destinationId.isAcceptableOrUnknown(
          data['destination_id']!,
          _destinationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_destinationIdMeta);
    }
    if (data.containsKey('origin_name')) {
      context.handle(
        _originNameMeta,
        originName.isAcceptableOrUnknown(data['origin_name']!, _originNameMeta),
      );
    } else if (isInserting) {
      context.missing(_originNameMeta);
    }
    if (data.containsKey('destination_name')) {
      context.handle(
        _destinationNameMeta,
        destinationName.isAcceptableOrUnknown(
          data['destination_name']!,
          _destinationNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_destinationNameMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endedAtMeta);
    }
    if (data.containsKey('reached_destination')) {
      context.handle(
        _reachedDestinationMeta,
        reachedDestination.isAcceptableOrUnknown(
          data['reached_destination']!,
          _reachedDestinationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reachedDestinationMeta);
    }
    if (data.containsKey('station_count')) {
      context.handle(
        _stationCountMeta,
        stationCount.isAcceptableOrUnknown(
          data['station_count']!,
          _stationCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_stationCountMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  JourneyRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JourneyRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      originId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin_id'],
      )!,
      destinationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destination_id'],
      )!,
      originName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin_name'],
      )!,
      destinationName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destination_name'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}ended_at'],
      )!,
      reachedDestination: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}reached_destination'],
      )!,
      stationCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}station_count'],
      )!,
    );
  }

  @override
  $JourneyRecordsTable createAlias(String alias) {
    return $JourneyRecordsTable(attachedDatabase, alias);
  }
}

class JourneyRecord extends DataClass implements Insertable<JourneyRecord> {
  final int id;
  final String originId;
  final String destinationId;
  final String originName;
  final String destinationName;
  final DateTime startedAt;
  final DateTime endedAt;

  /// True only when the destination arrival announcement actually spoke,
  /// the same signal the turnaround gate trusts. An early End stays false.
  final bool reachedDestination;

  /// Stations in the planned chain, overshoot pin excluded, so the row can
  /// say "8 stations" without replanning a route that may no longer exist.
  final int stationCount;
  const JourneyRecord({
    required this.id,
    required this.originId,
    required this.destinationId,
    required this.originName,
    required this.destinationName,
    required this.startedAt,
    required this.endedAt,
    required this.reachedDestination,
    required this.stationCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['origin_id'] = Variable<String>(originId);
    map['destination_id'] = Variable<String>(destinationId);
    map['origin_name'] = Variable<String>(originName);
    map['destination_name'] = Variable<String>(destinationName);
    map['started_at'] = Variable<DateTime>(startedAt);
    map['ended_at'] = Variable<DateTime>(endedAt);
    map['reached_destination'] = Variable<bool>(reachedDestination);
    map['station_count'] = Variable<int>(stationCount);
    return map;
  }

  JourneyRecordsCompanion toCompanion(bool nullToAbsent) {
    return JourneyRecordsCompanion(
      id: Value(id),
      originId: Value(originId),
      destinationId: Value(destinationId),
      originName: Value(originName),
      destinationName: Value(destinationName),
      startedAt: Value(startedAt),
      endedAt: Value(endedAt),
      reachedDestination: Value(reachedDestination),
      stationCount: Value(stationCount),
    );
  }

  factory JourneyRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JourneyRecord(
      id: serializer.fromJson<int>(json['id']),
      originId: serializer.fromJson<String>(json['originId']),
      destinationId: serializer.fromJson<String>(json['destinationId']),
      originName: serializer.fromJson<String>(json['originName']),
      destinationName: serializer.fromJson<String>(json['destinationName']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      endedAt: serializer.fromJson<DateTime>(json['endedAt']),
      reachedDestination: serializer.fromJson<bool>(json['reachedDestination']),
      stationCount: serializer.fromJson<int>(json['stationCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'originId': serializer.toJson<String>(originId),
      'destinationId': serializer.toJson<String>(destinationId),
      'originName': serializer.toJson<String>(originName),
      'destinationName': serializer.toJson<String>(destinationName),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'endedAt': serializer.toJson<DateTime>(endedAt),
      'reachedDestination': serializer.toJson<bool>(reachedDestination),
      'stationCount': serializer.toJson<int>(stationCount),
    };
  }

  JourneyRecord copyWith({
    int? id,
    String? originId,
    String? destinationId,
    String? originName,
    String? destinationName,
    DateTime? startedAt,
    DateTime? endedAt,
    bool? reachedDestination,
    int? stationCount,
  }) => JourneyRecord(
    id: id ?? this.id,
    originId: originId ?? this.originId,
    destinationId: destinationId ?? this.destinationId,
    originName: originName ?? this.originName,
    destinationName: destinationName ?? this.destinationName,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    reachedDestination: reachedDestination ?? this.reachedDestination,
    stationCount: stationCount ?? this.stationCount,
  );
  JourneyRecord copyWithCompanion(JourneyRecordsCompanion data) {
    return JourneyRecord(
      id: data.id.present ? data.id.value : this.id,
      originId: data.originId.present ? data.originId.value : this.originId,
      destinationId: data.destinationId.present
          ? data.destinationId.value
          : this.destinationId,
      originName: data.originName.present
          ? data.originName.value
          : this.originName,
      destinationName: data.destinationName.present
          ? data.destinationName.value
          : this.destinationName,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      reachedDestination: data.reachedDestination.present
          ? data.reachedDestination.value
          : this.reachedDestination,
      stationCount: data.stationCount.present
          ? data.stationCount.value
          : this.stationCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JourneyRecord(')
          ..write('id: $id, ')
          ..write('originId: $originId, ')
          ..write('destinationId: $destinationId, ')
          ..write('originName: $originName, ')
          ..write('destinationName: $destinationName, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('reachedDestination: $reachedDestination, ')
          ..write('stationCount: $stationCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    originId,
    destinationId,
    originName,
    destinationName,
    startedAt,
    endedAt,
    reachedDestination,
    stationCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JourneyRecord &&
          other.id == this.id &&
          other.originId == this.originId &&
          other.destinationId == this.destinationId &&
          other.originName == this.originName &&
          other.destinationName == this.destinationName &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.reachedDestination == this.reachedDestination &&
          other.stationCount == this.stationCount);
}

class JourneyRecordsCompanion extends UpdateCompanion<JourneyRecord> {
  final Value<int> id;
  final Value<String> originId;
  final Value<String> destinationId;
  final Value<String> originName;
  final Value<String> destinationName;
  final Value<DateTime> startedAt;
  final Value<DateTime> endedAt;
  final Value<bool> reachedDestination;
  final Value<int> stationCount;
  const JourneyRecordsCompanion({
    this.id = const Value.absent(),
    this.originId = const Value.absent(),
    this.destinationId = const Value.absent(),
    this.originName = const Value.absent(),
    this.destinationName = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.reachedDestination = const Value.absent(),
    this.stationCount = const Value.absent(),
  });
  JourneyRecordsCompanion.insert({
    this.id = const Value.absent(),
    required String originId,
    required String destinationId,
    required String originName,
    required String destinationName,
    required DateTime startedAt,
    required DateTime endedAt,
    required bool reachedDestination,
    required int stationCount,
  }) : originId = Value(originId),
       destinationId = Value(destinationId),
       originName = Value(originName),
       destinationName = Value(destinationName),
       startedAt = Value(startedAt),
       endedAt = Value(endedAt),
       reachedDestination = Value(reachedDestination),
       stationCount = Value(stationCount);
  static Insertable<JourneyRecord> custom({
    Expression<int>? id,
    Expression<String>? originId,
    Expression<String>? destinationId,
    Expression<String>? originName,
    Expression<String>? destinationName,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? endedAt,
    Expression<bool>? reachedDestination,
    Expression<int>? stationCount,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (originId != null) 'origin_id': originId,
      if (destinationId != null) 'destination_id': destinationId,
      if (originName != null) 'origin_name': originName,
      if (destinationName != null) 'destination_name': destinationName,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (reachedDestination != null) 'reached_destination': reachedDestination,
      if (stationCount != null) 'station_count': stationCount,
    });
  }

  JourneyRecordsCompanion copyWith({
    Value<int>? id,
    Value<String>? originId,
    Value<String>? destinationId,
    Value<String>? originName,
    Value<String>? destinationName,
    Value<DateTime>? startedAt,
    Value<DateTime>? endedAt,
    Value<bool>? reachedDestination,
    Value<int>? stationCount,
  }) {
    return JourneyRecordsCompanion(
      id: id ?? this.id,
      originId: originId ?? this.originId,
      destinationId: destinationId ?? this.destinationId,
      originName: originName ?? this.originName,
      destinationName: destinationName ?? this.destinationName,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      reachedDestination: reachedDestination ?? this.reachedDestination,
      stationCount: stationCount ?? this.stationCount,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (originId.present) {
      map['origin_id'] = Variable<String>(originId.value);
    }
    if (destinationId.present) {
      map['destination_id'] = Variable<String>(destinationId.value);
    }
    if (originName.present) {
      map['origin_name'] = Variable<String>(originName.value);
    }
    if (destinationName.present) {
      map['destination_name'] = Variable<String>(destinationName.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<DateTime>(endedAt.value);
    }
    if (reachedDestination.present) {
      map['reached_destination'] = Variable<bool>(reachedDestination.value);
    }
    if (stationCount.present) {
      map['station_count'] = Variable<int>(stationCount.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JourneyRecordsCompanion(')
          ..write('id: $id, ')
          ..write('originId: $originId, ')
          ..write('destinationId: $destinationId, ')
          ..write('originName: $originName, ')
          ..write('destinationName: $destinationName, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('reachedDestination: $reachedDestination, ')
          ..write('stationCount: $stationCount')
          ..write(')'))
        .toString();
  }
}

abstract class _$JourneyHistoryDatabase extends GeneratedDatabase {
  _$JourneyHistoryDatabase(QueryExecutor e) : super(e);
  $JourneyHistoryDatabaseManager get managers =>
      $JourneyHistoryDatabaseManager(this);
  late final $JourneyRecordsTable journeyRecords = $JourneyRecordsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [journeyRecords];
}

typedef $$JourneyRecordsTableCreateCompanionBuilder =
    JourneyRecordsCompanion Function({
      Value<int> id,
      required String originId,
      required String destinationId,
      required String originName,
      required String destinationName,
      required DateTime startedAt,
      required DateTime endedAt,
      required bool reachedDestination,
      required int stationCount,
    });
typedef $$JourneyRecordsTableUpdateCompanionBuilder =
    JourneyRecordsCompanion Function({
      Value<int> id,
      Value<String> originId,
      Value<String> destinationId,
      Value<String> originName,
      Value<String> destinationName,
      Value<DateTime> startedAt,
      Value<DateTime> endedAt,
      Value<bool> reachedDestination,
      Value<int> stationCount,
    });

class $$JourneyRecordsTableFilterComposer
    extends Composer<_$JourneyHistoryDatabase, $JourneyRecordsTable> {
  $$JourneyRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originId => $composableBuilder(
    column: $table.originId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get destinationId => $composableBuilder(
    column: $table.destinationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get reachedDestination => $composableBuilder(
    column: $table.reachedDestination,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stationCount => $composableBuilder(
    column: $table.stationCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JourneyRecordsTableOrderingComposer
    extends Composer<_$JourneyHistoryDatabase, $JourneyRecordsTable> {
  $$JourneyRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originId => $composableBuilder(
    column: $table.originId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get destinationId => $composableBuilder(
    column: $table.destinationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get reachedDestination => $composableBuilder(
    column: $table.reachedDestination,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stationCount => $composableBuilder(
    column: $table.stationCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JourneyRecordsTableAnnotationComposer
    extends Composer<_$JourneyHistoryDatabase, $JourneyRecordsTable> {
  $$JourneyRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get originId =>
      $composableBuilder(column: $table.originId, builder: (column) => column);

  GeneratedColumn<String> get destinationId => $composableBuilder(
    column: $table.destinationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<bool> get reachedDestination => $composableBuilder(
    column: $table.reachedDestination,
    builder: (column) => column,
  );

  GeneratedColumn<int> get stationCount => $composableBuilder(
    column: $table.stationCount,
    builder: (column) => column,
  );
}

class $$JourneyRecordsTableTableManager
    extends
        RootTableManager<
          _$JourneyHistoryDatabase,
          $JourneyRecordsTable,
          JourneyRecord,
          $$JourneyRecordsTableFilterComposer,
          $$JourneyRecordsTableOrderingComposer,
          $$JourneyRecordsTableAnnotationComposer,
          $$JourneyRecordsTableCreateCompanionBuilder,
          $$JourneyRecordsTableUpdateCompanionBuilder,
          (
            JourneyRecord,
            BaseReferences<
              _$JourneyHistoryDatabase,
              $JourneyRecordsTable,
              JourneyRecord
            >,
          ),
          JourneyRecord,
          PrefetchHooks Function()
        > {
  $$JourneyRecordsTableTableManager(
    _$JourneyHistoryDatabase db,
    $JourneyRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JourneyRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JourneyRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$JourneyRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> originId = const Value.absent(),
                Value<String> destinationId = const Value.absent(),
                Value<String> originName = const Value.absent(),
                Value<String> destinationName = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime> endedAt = const Value.absent(),
                Value<bool> reachedDestination = const Value.absent(),
                Value<int> stationCount = const Value.absent(),
              }) => JourneyRecordsCompanion(
                id: id,
                originId: originId,
                destinationId: destinationId,
                originName: originName,
                destinationName: destinationName,
                startedAt: startedAt,
                endedAt: endedAt,
                reachedDestination: reachedDestination,
                stationCount: stationCount,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String originId,
                required String destinationId,
                required String originName,
                required String destinationName,
                required DateTime startedAt,
                required DateTime endedAt,
                required bool reachedDestination,
                required int stationCount,
              }) => JourneyRecordsCompanion.insert(
                id: id,
                originId: originId,
                destinationId: destinationId,
                originName: originName,
                destinationName: destinationName,
                startedAt: startedAt,
                endedAt: endedAt,
                reachedDestination: reachedDestination,
                stationCount: stationCount,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$JourneyRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$JourneyHistoryDatabase,
      $JourneyRecordsTable,
      JourneyRecord,
      $$JourneyRecordsTableFilterComposer,
      $$JourneyRecordsTableOrderingComposer,
      $$JourneyRecordsTableAnnotationComposer,
      $$JourneyRecordsTableCreateCompanionBuilder,
      $$JourneyRecordsTableUpdateCompanionBuilder,
      (
        JourneyRecord,
        BaseReferences<
          _$JourneyHistoryDatabase,
          $JourneyRecordsTable,
          JourneyRecord
        >,
      ),
      JourneyRecord,
      PrefetchHooks Function()
    >;

class $JourneyHistoryDatabaseManager {
  final _$JourneyHistoryDatabase _db;
  $JourneyHistoryDatabaseManager(this._db);
  $$JourneyRecordsTableTableManager get journeyRecords =>
      $$JourneyRecordsTableTableManager(_db, _db.journeyRecords);
}
