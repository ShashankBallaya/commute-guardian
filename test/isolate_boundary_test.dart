import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The isolate boundary is an architectural invariant, so it is enforced by a
/// test rather than by good intentions.
///
/// Riverpod providers do not cross isolates. The ride runs in the foreground
/// service isolate and the UI cannot observe it directly, only send commands
/// into it and receive events back. Every one of those crossings goes through
/// RideServiceClient (UI side) or the task handler (service side), so a
/// reviewer can find all of them by opening two files.
///
/// The failure this prevents is not untidiness. A widget that talks to the
/// plugin directly looks fine in a test and on a desk, and fails on a locked
/// phone in a pocket, which is where every hard bug in this project has lived.
///
/// Same enforcement-by-test pattern as the clip copy test, which parses
/// build_clip_pack.py so the factory and the code cannot drift apart.
void main() {
  test('the UI isolate reaches the service through exactly one door', () {
    // Two sides, two rules.
    //
    // UI ISOLATE: exactly one file may touch the plugin or the native media
    // channel, and that is the client. Everything else asks it.
    //
    // SERVICE ISOLATE: these files ARE the service, so they use the plugin
    // freely. geofence_task_handler.dart owns the bridge itself
    // (sendDataToMain, saveData); geofence_chain_service.dart additionally
    // queries battery-optimization state to log the permission picture at
    // ride start, which is not bridge traffic at all.
    //
    // permissions_gateway.dart is allowed for THAT SAME REASON and no other,
    // added 12 Aug 2026 when Settings' readiness card was wired to real values.
    // Battery optimisation is a permission question that this plugin happens to
    // answer: no isolate is started, nothing is sent or received, and the
    // service is not involved. Routing it through RideServiceClient would mean
    // a card in Settings could only be drawn while a RIDE was running, which
    // inverts the point of a readiness check. The gateway is already this app's
    // one door to permission plugins, so the call is behind a door either way.
    //
    // THE LINE THIS DOES NOT CROSS: no sendDataToMain, no saveData, no starting
    // or stopping a service. If a future edit adds one of those here, move it
    // to RideServiceClient instead of widening this comment.
    const allowed = {
      'lib/services/ride_service_client.dart',
      'lib/foreground/geofence_task_handler.dart',
      'lib/services/geofence_chain_service.dart',
      'lib/services/permissions_gateway.dart',
    };

    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) continue;
      if (_containsBridgeCode(entity.readAsStringSync())) {
        offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files reach across the isolate boundary directly. Route '
          'the call through RideServiceClient instead, or add the file to the '
          'allowed set and say why in docs/design/riverpod-adoption.md.',
    );
  });

  test('the allowed files still exist, so the test cannot pass vacuously', () {
    expect(File('lib/services/ride_service_client.dart').existsSync(), isTrue);
    expect(
      File('lib/foreground/geofence_task_handler.dart').existsSync(),
      isTrue,
    );
  });

  test('no widget holds ride or journey state in a field', () {
    // The migration's finishing line, kept as a test so it cannot quietly
    // un-finish. These names all used to be fields on _RideDebugScreenState,
    // and losing them with the widget is exactly what blanked the route when
    // Android recreated the activity mid-ride on 15 Jul. They live in
    // providers now (lib/state/), where a rebuilt screen re-reads them.
    //
    // Deliberately NOT a ban on setState. The screen still owns ephemeral
    // things (the debug log, the chip tip, two bench flags, a search query),
    // and the design says it should: their loss on process death costs the
    // rider nothing.
    const forbidden = [
      '_isRunning',
      '_wakeLadderLive',
      '_windDownLive',
      '_journey',
      '_planError',
      '_originId',
      '_destinationId',
      '_gpsState',
      '_nearStationName',
      '_repo',
      '_stations',
    ];

    final source = File('lib/main.dart').readAsStringSync();
    final found = forbidden.where((name) => _holdsField(source, name)).toList();
    expect(
      found,
      isEmpty,
      reason:
          'Ride and journey state belongs in lib/state/, not in a widget '
          'field. See docs/design/riverpod-adoption.md.',
    );
  });

  test('THE FIELD CHECK MATCHES WHOLE NAMES, not substrings', () {
    // It was a bare `source.contains` until 8 Aug 2026, and it flagged
    // `_repo` inside `crash_reporting.dart` and `bug_report_outlined`. Two of
    // the names carried a trailing space as a hand-made fix for the same
    // problem, which only worked where the field happened to be followed by
    // one. A word boundary does the job for every name, so the trailing spaces
    // are gone.
    //
    // The guard has to keep its teeth, so this proves both directions rather
    // than trusting the regex by eye.
    for (final innocent in const [
      "import 'services/crash_reporting.dart';",
      'Icons.bug_report_outlined,',
      "import '../data/station_repository.dart';",
      'final draft = ref.read(_journeyDraftProvider);',
      'ref.watch(stationsAlphabeticalProvider);',
    ]) {
      expect(_holdsField(innocent, '_repo'), isFalse, reason: innocent);
      expect(_holdsField(innocent, '_journey'), isFalse, reason: innocent);
      expect(_holdsField(innocent, '_stations'), isFalse, reason: innocent);
    }

    for (final guilty in const [
      'StationRepository? _repo;',
      '  final _repo = ref.read(stationRepositoryProvider);',
      'Journey? _journey;',
      'List<Station> _stations = [];',
      '_repo = await StationRepository.load();',
    ]) {
      final tripped = [
        '_repo',
        '_journey',
        '_stations',
      ].where((name) => _holdsField(guilty, name)).toList();
      expect(tripped, isNotEmpty, reason: guilty);
    }
  });

  test('the detector reads code and ignores prose', () {
    // Comments discuss the bridge constantly and must not trip the check;
    // the first draft of this test flagged two files for their doc comments.
    expect(
      _containsBridgeCode('// FlutterForegroundTask is the bridge'),
      isFalse,
    );
    expect(_containsBridgeCode('/// hops over media_ack'), isFalse);
    expect(_containsBridgeCode('/* FlutterForegroundTask */'), isFalse);
    // Real code still trips it, both the import and the identifier.
    expect(
      _containsBridgeCode(
        "import 'package:flutter_foreground_task/flutter_foreground_task.dart';",
      ),
      isTrue,
    );
    expect(
      _containsBridgeCode('await FlutterForegroundTask.stopService();'),
      isTrue,
    );
    expect(
      _containsBridgeCode(
        "const c = MethodChannel('commute_guardian/media_ack');",
      ),
      isTrue,
    );
  });
}

/// True when [source] reaches across the isolate boundary in CODE.
///
/// Comments are stripped first: this codebase explains the bridge in prose in
/// many files, and flagging those would train everyone to ignore the test.
/// A `//` inside a string literal would truncate that line early, which could
/// in principle hide a match sharing the line. Accepted: the alternative is a
/// Dart parser for a guard rail.
bool _containsBridgeCode(String source) {
  final code = source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment == -1 ? line : line.substring(0, comment);
      })
      .join('\n');
  return code.contains('flutter_foreground_task') ||
      code.contains('FlutterForegroundTask') ||
      code.contains('media_ack');
}

/// Whether [source] uses [name] as a whole identifier rather than as part of a
/// longer one.
///
/// The trailing boundary is the point: `_repo` must not match inside
/// `crash_reporting`, `bug_report_outlined` or `station_repository`, and
/// `_journey` must not match inside `_journeyDraftProvider`. The leading one
/// matters too, so a field called `_myRepo` stays its own name.
bool _holdsField(String source, String name) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
).hasMatch(source);
