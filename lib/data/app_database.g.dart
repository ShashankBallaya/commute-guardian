// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

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
  static const VerificationMeta _batteryStartPctMeta = const VerificationMeta(
    'batteryStartPct',
  );
  @override
  late final GeneratedColumn<int> batteryStartPct = GeneratedColumn<int>(
    'battery_start_pct',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _batteryEndPctMeta = const VerificationMeta(
    'batteryEndPct',
  );
  @override
  late final GeneratedColumn<int> batteryEndPct = GeneratedColumn<int>(
    'battery_end_pct',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
    batteryStartPct,
    batteryEndPct,
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
    if (data.containsKey('battery_start_pct')) {
      context.handle(
        _batteryStartPctMeta,
        batteryStartPct.isAcceptableOrUnknown(
          data['battery_start_pct']!,
          _batteryStartPctMeta,
        ),
      );
    }
    if (data.containsKey('battery_end_pct')) {
      context.handle(
        _batteryEndPctMeta,
        batteryEndPct.isAcceptableOrUnknown(
          data['battery_end_pct']!,
          _batteryEndPctMeta,
        ),
      );
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
      batteryStartPct: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}battery_start_pct'],
      ),
      batteryEndPct: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}battery_end_pct'],
      ),
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
  final int? batteryStartPct;
  final int? batteryEndPct;
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
    this.batteryStartPct,
    this.batteryEndPct,
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
    if (!nullToAbsent || batteryStartPct != null) {
      map['battery_start_pct'] = Variable<int>(batteryStartPct);
    }
    if (!nullToAbsent || batteryEndPct != null) {
      map['battery_end_pct'] = Variable<int>(batteryEndPct);
    }
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
      batteryStartPct: batteryStartPct == null && nullToAbsent
          ? const Value.absent()
          : Value(batteryStartPct),
      batteryEndPct: batteryEndPct == null && nullToAbsent
          ? const Value.absent()
          : Value(batteryEndPct),
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
      batteryStartPct: serializer.fromJson<int?>(json['batteryStartPct']),
      batteryEndPct: serializer.fromJson<int?>(json['batteryEndPct']),
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
      'batteryStartPct': serializer.toJson<int?>(batteryStartPct),
      'batteryEndPct': serializer.toJson<int?>(batteryEndPct),
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
    Value<int?> batteryStartPct = const Value.absent(),
    Value<int?> batteryEndPct = const Value.absent(),
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
    batteryStartPct: batteryStartPct.present
        ? batteryStartPct.value
        : this.batteryStartPct,
    batteryEndPct: batteryEndPct.present
        ? batteryEndPct.value
        : this.batteryEndPct,
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
      batteryStartPct: data.batteryStartPct.present
          ? data.batteryStartPct.value
          : this.batteryStartPct,
      batteryEndPct: data.batteryEndPct.present
          ? data.batteryEndPct.value
          : this.batteryEndPct,
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
          ..write('stationCount: $stationCount, ')
          ..write('batteryStartPct: $batteryStartPct, ')
          ..write('batteryEndPct: $batteryEndPct')
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
    batteryStartPct,
    batteryEndPct,
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
          other.stationCount == this.stationCount &&
          other.batteryStartPct == this.batteryStartPct &&
          other.batteryEndPct == this.batteryEndPct);
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
  final Value<int?> batteryStartPct;
  final Value<int?> batteryEndPct;
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
    this.batteryStartPct = const Value.absent(),
    this.batteryEndPct = const Value.absent(),
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
    this.batteryStartPct = const Value.absent(),
    this.batteryEndPct = const Value.absent(),
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
    Expression<int>? batteryStartPct,
    Expression<int>? batteryEndPct,
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
      if (batteryStartPct != null) 'battery_start_pct': batteryStartPct,
      if (batteryEndPct != null) 'battery_end_pct': batteryEndPct,
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
    Value<int?>? batteryStartPct,
    Value<int?>? batteryEndPct,
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
      batteryStartPct: batteryStartPct ?? this.batteryStartPct,
      batteryEndPct: batteryEndPct ?? this.batteryEndPct,
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
    if (batteryStartPct.present) {
      map['battery_start_pct'] = Variable<int>(batteryStartPct.value);
    }
    if (batteryEndPct.present) {
      map['battery_end_pct'] = Variable<int>(batteryEndPct.value);
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
          ..write('stationCount: $stationCount, ')
          ..write('batteryStartPct: $batteryStartPct, ')
          ..write('batteryEndPct: $batteryEndPct')
          ..write(')'))
        .toString();
  }
}

class $SavedRoutesTable extends SavedRoutes
    with TableInfo<$SavedRoutesTable, SavedRoute> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SavedRoutesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _destinationStationIdMeta =
      const VerificationMeta('destinationStationId');
  @override
  late final GeneratedColumn<String> destinationStationId =
      GeneratedColumn<String>(
        'destination_station_id',
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
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    label,
    destinationStationId,
    destinationName,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'saved_routes';
  @override
  VerificationContext validateIntegrity(
    Insertable<SavedRoute> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('destination_station_id')) {
      context.handle(
        _destinationStationIdMeta,
        destinationStationId.isAcceptableOrUnknown(
          data['destination_station_id']!,
          _destinationStationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_destinationStationIdMeta);
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
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SavedRoute map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SavedRoute(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      )!,
      destinationStationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destination_station_id'],
      )!,
      destinationName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destination_name'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SavedRoutesTable createAlias(String alias) {
    return $SavedRoutesTable(attachedDatabase, alias);
  }
}

class SavedRoute extends DataClass implements Insertable<SavedRoute> {
  final int id;

  /// What the rider calls it: "Home", "Work". Asked for at journey end, when
  /// the route has proven real.
  final String label;
  final String destinationStationId;
  final String destinationName;
  final DateTime createdAt;
  const SavedRoute({
    required this.id,
    required this.label,
    required this.destinationStationId,
    required this.destinationName,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['label'] = Variable<String>(label);
    map['destination_station_id'] = Variable<String>(destinationStationId);
    map['destination_name'] = Variable<String>(destinationName);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SavedRoutesCompanion toCompanion(bool nullToAbsent) {
    return SavedRoutesCompanion(
      id: Value(id),
      label: Value(label),
      destinationStationId: Value(destinationStationId),
      destinationName: Value(destinationName),
      createdAt: Value(createdAt),
    );
  }

  factory SavedRoute.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SavedRoute(
      id: serializer.fromJson<int>(json['id']),
      label: serializer.fromJson<String>(json['label']),
      destinationStationId: serializer.fromJson<String>(
        json['destinationStationId'],
      ),
      destinationName: serializer.fromJson<String>(json['destinationName']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'label': serializer.toJson<String>(label),
      'destinationStationId': serializer.toJson<String>(destinationStationId),
      'destinationName': serializer.toJson<String>(destinationName),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SavedRoute copyWith({
    int? id,
    String? label,
    String? destinationStationId,
    String? destinationName,
    DateTime? createdAt,
  }) => SavedRoute(
    id: id ?? this.id,
    label: label ?? this.label,
    destinationStationId: destinationStationId ?? this.destinationStationId,
    destinationName: destinationName ?? this.destinationName,
    createdAt: createdAt ?? this.createdAt,
  );
  SavedRoute copyWithCompanion(SavedRoutesCompanion data) {
    return SavedRoute(
      id: data.id.present ? data.id.value : this.id,
      label: data.label.present ? data.label.value : this.label,
      destinationStationId: data.destinationStationId.present
          ? data.destinationStationId.value
          : this.destinationStationId,
      destinationName: data.destinationName.present
          ? data.destinationName.value
          : this.destinationName,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SavedRoute(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('destinationStationId: $destinationStationId, ')
          ..write('destinationName: $destinationName, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, label, destinationStationId, destinationName, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedRoute &&
          other.id == this.id &&
          other.label == this.label &&
          other.destinationStationId == this.destinationStationId &&
          other.destinationName == this.destinationName &&
          other.createdAt == this.createdAt);
}

class SavedRoutesCompanion extends UpdateCompanion<SavedRoute> {
  final Value<int> id;
  final Value<String> label;
  final Value<String> destinationStationId;
  final Value<String> destinationName;
  final Value<DateTime> createdAt;
  const SavedRoutesCompanion({
    this.id = const Value.absent(),
    this.label = const Value.absent(),
    this.destinationStationId = const Value.absent(),
    this.destinationName = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SavedRoutesCompanion.insert({
    this.id = const Value.absent(),
    required String label,
    required String destinationStationId,
    required String destinationName,
    required DateTime createdAt,
  }) : label = Value(label),
       destinationStationId = Value(destinationStationId),
       destinationName = Value(destinationName),
       createdAt = Value(createdAt);
  static Insertable<SavedRoute> custom({
    Expression<int>? id,
    Expression<String>? label,
    Expression<String>? destinationStationId,
    Expression<String>? destinationName,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (label != null) 'label': label,
      if (destinationStationId != null)
        'destination_station_id': destinationStationId,
      if (destinationName != null) 'destination_name': destinationName,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SavedRoutesCompanion copyWith({
    Value<int>? id,
    Value<String>? label,
    Value<String>? destinationStationId,
    Value<String>? destinationName,
    Value<DateTime>? createdAt,
  }) {
    return SavedRoutesCompanion(
      id: id ?? this.id,
      label: label ?? this.label,
      destinationStationId: destinationStationId ?? this.destinationStationId,
      destinationName: destinationName ?? this.destinationName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (destinationStationId.present) {
      map['destination_station_id'] = Variable<String>(
        destinationStationId.value,
      );
    }
    if (destinationName.present) {
      map['destination_name'] = Variable<String>(destinationName.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SavedRoutesCompanion(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('destinationStationId: $destinationStationId, ')
          ..write('destinationName: $destinationName, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $AppFlagsTable extends AppFlags with TableInfo<$AppFlagsTable, AppFlag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppFlagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_flags';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppFlag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppFlag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppFlag(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppFlagsTable createAlias(String alias) {
    return $AppFlagsTable(attachedDatabase, alias);
  }
}

class AppFlag extends DataClass implements Insertable<AppFlag> {
  final String key;
  final String value;
  const AppFlag({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppFlagsCompanion toCompanion(bool nullToAbsent) {
    return AppFlagsCompanion(key: Value(key), value: Value(value));
  }

  factory AppFlag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppFlag(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppFlag copyWith({String? key, String? value}) =>
      AppFlag(key: key ?? this.key, value: value ?? this.value);
  AppFlag copyWithCompanion(AppFlagsCompanion data) {
    return AppFlag(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppFlag(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppFlag && other.key == this.key && other.value == this.value);
}

class AppFlagsCompanion extends UpdateCompanion<AppFlag> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppFlagsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppFlagsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppFlag> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppFlagsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppFlagsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppFlagsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $JourneyRecordsTable journeyRecords = $JourneyRecordsTable(this);
  late final $SavedRoutesTable savedRoutes = $SavedRoutesTable(this);
  late final $AppFlagsTable appFlags = $AppFlagsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    journeyRecords,
    savedRoutes,
    appFlags,
  ];
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
      Value<int?> batteryStartPct,
      Value<int?> batteryEndPct,
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
      Value<int?> batteryStartPct,
      Value<int?> batteryEndPct,
    });

class $$JourneyRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $JourneyRecordsTable> {
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

  ColumnFilters<int> get batteryStartPct => $composableBuilder(
    column: $table.batteryStartPct,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get batteryEndPct => $composableBuilder(
    column: $table.batteryEndPct,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JourneyRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $JourneyRecordsTable> {
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

  ColumnOrderings<int> get batteryStartPct => $composableBuilder(
    column: $table.batteryStartPct,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get batteryEndPct => $composableBuilder(
    column: $table.batteryEndPct,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JourneyRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $JourneyRecordsTable> {
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

  GeneratedColumn<int> get batteryStartPct => $composableBuilder(
    column: $table.batteryStartPct,
    builder: (column) => column,
  );

  GeneratedColumn<int> get batteryEndPct => $composableBuilder(
    column: $table.batteryEndPct,
    builder: (column) => column,
  );
}

class $$JourneyRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $JourneyRecordsTable,
          JourneyRecord,
          $$JourneyRecordsTableFilterComposer,
          $$JourneyRecordsTableOrderingComposer,
          $$JourneyRecordsTableAnnotationComposer,
          $$JourneyRecordsTableCreateCompanionBuilder,
          $$JourneyRecordsTableUpdateCompanionBuilder,
          (
            JourneyRecord,
            BaseReferences<_$AppDatabase, $JourneyRecordsTable, JourneyRecord>,
          ),
          JourneyRecord,
          PrefetchHooks Function()
        > {
  $$JourneyRecordsTableTableManager(
    _$AppDatabase db,
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
                Value<int?> batteryStartPct = const Value.absent(),
                Value<int?> batteryEndPct = const Value.absent(),
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
                batteryStartPct: batteryStartPct,
                batteryEndPct: batteryEndPct,
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
                Value<int?> batteryStartPct = const Value.absent(),
                Value<int?> batteryEndPct = const Value.absent(),
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
                batteryStartPct: batteryStartPct,
                batteryEndPct: batteryEndPct,
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
      _$AppDatabase,
      $JourneyRecordsTable,
      JourneyRecord,
      $$JourneyRecordsTableFilterComposer,
      $$JourneyRecordsTableOrderingComposer,
      $$JourneyRecordsTableAnnotationComposer,
      $$JourneyRecordsTableCreateCompanionBuilder,
      $$JourneyRecordsTableUpdateCompanionBuilder,
      (
        JourneyRecord,
        BaseReferences<_$AppDatabase, $JourneyRecordsTable, JourneyRecord>,
      ),
      JourneyRecord,
      PrefetchHooks Function()
    >;
typedef $$SavedRoutesTableCreateCompanionBuilder =
    SavedRoutesCompanion Function({
      Value<int> id,
      required String label,
      required String destinationStationId,
      required String destinationName,
      required DateTime createdAt,
    });
typedef $$SavedRoutesTableUpdateCompanionBuilder =
    SavedRoutesCompanion Function({
      Value<int> id,
      Value<String> label,
      Value<String> destinationStationId,
      Value<String> destinationName,
      Value<DateTime> createdAt,
    });

class $$SavedRoutesTableFilterComposer
    extends Composer<_$AppDatabase, $SavedRoutesTable> {
  $$SavedRoutesTableFilterComposer({
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

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get destinationStationId => $composableBuilder(
    column: $table.destinationStationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SavedRoutesTableOrderingComposer
    extends Composer<_$AppDatabase, $SavedRoutesTable> {
  $$SavedRoutesTableOrderingComposer({
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

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get destinationStationId => $composableBuilder(
    column: $table.destinationStationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SavedRoutesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SavedRoutesTable> {
  $$SavedRoutesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get destinationStationId => $composableBuilder(
    column: $table.destinationStationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get destinationName => $composableBuilder(
    column: $table.destinationName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$SavedRoutesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SavedRoutesTable,
          SavedRoute,
          $$SavedRoutesTableFilterComposer,
          $$SavedRoutesTableOrderingComposer,
          $$SavedRoutesTableAnnotationComposer,
          $$SavedRoutesTableCreateCompanionBuilder,
          $$SavedRoutesTableUpdateCompanionBuilder,
          (
            SavedRoute,
            BaseReferences<_$AppDatabase, $SavedRoutesTable, SavedRoute>,
          ),
          SavedRoute,
          PrefetchHooks Function()
        > {
  $$SavedRoutesTableTableManager(_$AppDatabase db, $SavedRoutesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SavedRoutesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SavedRoutesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SavedRoutesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> label = const Value.absent(),
                Value<String> destinationStationId = const Value.absent(),
                Value<String> destinationName = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SavedRoutesCompanion(
                id: id,
                label: label,
                destinationStationId: destinationStationId,
                destinationName: destinationName,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String label,
                required String destinationStationId,
                required String destinationName,
                required DateTime createdAt,
              }) => SavedRoutesCompanion.insert(
                id: id,
                label: label,
                destinationStationId: destinationStationId,
                destinationName: destinationName,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SavedRoutesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SavedRoutesTable,
      SavedRoute,
      $$SavedRoutesTableFilterComposer,
      $$SavedRoutesTableOrderingComposer,
      $$SavedRoutesTableAnnotationComposer,
      $$SavedRoutesTableCreateCompanionBuilder,
      $$SavedRoutesTableUpdateCompanionBuilder,
      (
        SavedRoute,
        BaseReferences<_$AppDatabase, $SavedRoutesTable, SavedRoute>,
      ),
      SavedRoute,
      PrefetchHooks Function()
    >;
typedef $$AppFlagsTableCreateCompanionBuilder =
    AppFlagsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppFlagsTableUpdateCompanionBuilder =
    AppFlagsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppFlagsTableFilterComposer
    extends Composer<_$AppDatabase, $AppFlagsTable> {
  $$AppFlagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppFlagsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppFlagsTable> {
  $$AppFlagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppFlagsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppFlagsTable> {
  $$AppFlagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppFlagsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppFlagsTable,
          AppFlag,
          $$AppFlagsTableFilterComposer,
          $$AppFlagsTableOrderingComposer,
          $$AppFlagsTableAnnotationComposer,
          $$AppFlagsTableCreateCompanionBuilder,
          $$AppFlagsTableUpdateCompanionBuilder,
          (AppFlag, BaseReferences<_$AppDatabase, $AppFlagsTable, AppFlag>),
          AppFlag,
          PrefetchHooks Function()
        > {
  $$AppFlagsTableTableManager(_$AppDatabase db, $AppFlagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppFlagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppFlagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppFlagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppFlagsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppFlagsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppFlagsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppFlagsTable,
      AppFlag,
      $$AppFlagsTableFilterComposer,
      $$AppFlagsTableOrderingComposer,
      $$AppFlagsTableAnnotationComposer,
      $$AppFlagsTableCreateCompanionBuilder,
      $$AppFlagsTableUpdateCompanionBuilder,
      (AppFlag, BaseReferences<_$AppDatabase, $AppFlagsTable, AppFlag>),
      AppFlag,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$JourneyRecordsTableTableManager get journeyRecords =>
      $$JourneyRecordsTableTableManager(_db, _db.journeyRecords);
  $$SavedRoutesTableTableManager get savedRoutes =>
      $$SavedRoutesTableTableManager(_db, _db.savedRoutes);
  $$AppFlagsTableTableManager get appFlags =>
      $$AppFlagsTableTableManager(_db, _db.appFlags);
}
