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
    const allowed = {
      'lib/services/ride_service_client.dart',
      'lib/foreground/geofence_task_handler.dart',
      'lib/services/geofence_chain_service.dart',
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
      reason: 'These files reach across the isolate boundary directly. Route '
          'the call through RideServiceClient instead, or add the file to the '
          'allowed set and say why in docs/design/riverpod-adoption.md.',
    );
  });

  test('the allowed files still exist, so the test cannot pass vacuously', () {
    expect(File('lib/services/ride_service_client.dart').existsSync(), isTrue);
    expect(File('lib/foreground/geofence_task_handler.dart').existsSync(),
        isTrue);
  });

  test('the detector reads code and ignores prose', () {
    // Comments discuss the bridge constantly and must not trip the check;
    // the first draft of this test flagged two files for their doc comments.
    expect(_containsBridgeCode('// FlutterForegroundTask is the bridge'), isFalse);
    expect(_containsBridgeCode('/// hops over media_ack'), isFalse);
    expect(_containsBridgeCode('/* FlutterForegroundTask */'), isFalse);
    // Real code still trips it, both the import and the identifier.
    expect(
      _containsBridgeCode(
        "import 'package:flutter_foreground_task/flutter_foreground_task.dart';",
      ),
      isTrue,
    );
    expect(_containsBridgeCode('await FlutterForegroundTask.stopService();'),
        isTrue);
    expect(
      _containsBridgeCode("const c = MethodChannel('commute_guardian/media_ack');"),
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
