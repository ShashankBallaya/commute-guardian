import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Swift half of the relaunch lifeline, guarded at the desk.
///
/// WHY A TEST READS SOURCE. Swift does not compile on the machine this project
/// is written on, so the first check on any change to `AppDelegate.swift` is a
/// macOS runner, and there are about eight to twelve of those a month. On
/// 18 Aug 2026 one was spent learning that `setPluginRegistrantCallback` takes
/// a C function pointer, so its closure may capture nothing at all. These
/// guards hold the shape that answer forced, for free.
///
/// WHAT THEY CANNOT DO. None of this proves the code compiles, and none of it
/// proves iOS ever wakes the app. It proves the four things that were true
/// when it was written and are invisible from Dart: the launch is inspected,
/// monitoring is restarted, the channel exists on both engines, and the
/// registration function stays at file scope.
void main() {
  final source = File(
    'ios/Runner/AppDelegate.swift',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  /// [code] with every comment line removed.
  ///
  /// COMMENTS STRIPPED ON PURPOSE. Five guards in this project have passed on
  /// prose that merely mentioned the thing they were meant to find, and the
  /// lifeline's own comments discuss every symbol below at length.
  String stripComments(String code) => code
      .split('\n')
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//') && !trimmed.startsWith('///');
      })
      .join('\n');

  final body = stripComments(source);
  final collapsed = body.replaceAll(RegExp(r'\s+'), ' ');

  /// The body of a Swift method declared at one level of indentation.
  String methodBody(String signature) {
    final start = body.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature must exist');
    final end = body.indexOf('\n  }', start);
    expect(end, isNonNegative, reason: '$signature must close');
    return body.substring(start, end);
  }

  group('THE APP ASKS iOS TO WAKE IT, and reads the answer', () {
    test('the launch options are inspected before Dart runs', () {
      // The only moment iOS offers this. Miss it and the app can never know
      // it was started by movement rather than by a rider.
      expect(
        collapsed,
        contains('relaunchLifeline.noteLaunch(options: launchOptions)'),
        reason: 'didFinishLaunchingWithOptions must hand over the options',
      );
    });

    test('MONITORING IS RESTARTED ON A RELAUNCH, which Apple requires', () {
      // A relaunched app must call startMonitoringSignificantLocationChanges
      // again to receive the event that woke it. Without it the app is started,
      // learns nothing and goes back to sleep, which is worse than not being
      // started at all because it looks like it worked.
      expect(
        methodBody('func noteLaunch('),
        contains('startMonitoringSignificantLocationChanges()'),
      );
    });

    test('the launch key is what decides it, not a guess', () {
      expect(methodBody('func noteLaunch('), contains('options?[.location]'));
    });
  });

  group('THE CHANNEL EXISTS ON BOTH ENGINES', () {
    test('registered twice, once per engine', () {
      // The SERVICE arms and disarms the lifeline, because it owns both edges
      // of a ride. The IMPLICIT engine answers the relaunch, because after a
      // kill the service isolate is exactly what no longer exists.
      final registrations = 'registerRelaunchChannel(with:'.allMatches(body);
      expect(
        registrations.length,
        2,
        reason: 'one call for the service engine, one for the implicit engine',
      );
    });

    test('and Dart reaches it by the name Dart uses', () {
      expect(collapsed, contains('name: "commute_guardian/relaunch"'));
    });
  });

  group('THE REGISTRATION FUNCTION STAYS AT FILE SCOPE', () {
    // NOT STYLE. setPluginRegistrantCallback takes a C FUNCTION POINTER, so the
    // closure that calls this may capture nothing, `self` included. Written as
    // a method it fails to compile, and CI is the only place that would say so.
    test('declared at column zero, outside the class', () {
      expect(
        body,
        contains('\nprivate func registerRelaunchChannel('),
        reason: 'an indented declaration is a method, and a method cannot be '
            'called from a C function pointer closure',
      );
    });

    test('and so does the instance it reaches for', () {
      expect(body, contains('\nprivate let relaunchLifeline = '));
    });

    test('THE GUARD CAN STILL FAIL: an indented declaration is not file scope',
        () {
      const indented = '''
class Thing {
  private func registerRelaunchChannel(with registry: FlutterPluginRegistry) {}
}''';
      expect(
        indented,
        isNot(contains('\nprivate func registerRelaunchChannel(')),
        reason: 'a method must not satisfy the file-scope guard',
      );
    });
  });

  group('THE FRAMEWORKS IT NEEDS ARE IMPORTED', () {
    test('CoreLocation for the lifeline, UserNotifications for the notice', () {
      expect(body, contains('\nimport CoreLocation'));
      expect(body, contains('\nimport UserNotifications'));
    });
  });
}
