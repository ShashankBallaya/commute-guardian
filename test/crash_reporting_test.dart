import 'dart:io';

import 'package:commute_guardian/services/crash_reporting.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scrubber, which is the only part of crash reporting worth testing and
/// the part that must never quietly stop working.
///
/// The rule it enforces is the Phase 4 privacy note: no location ever leaves
/// the device. Sentry's own collectors are all switched off in
/// `crash_reporting.dart`, so this is the second line, for a coordinate that
/// reaches an exception message by a route nobody predicted.
///
/// The inputs are REAL LINES from the ride logs and from the packages this app
/// uses, not invented ones. A scrubber tested against its own regex proves
/// nothing.
void main() {
  group('scrubLocation', () {
    test('THE LINE EVERY RIDE WRITES THOUSANDS OF TIMES', () {
      const line =
          'FIX lat 19.2358216, lng 73.1308101, accuracy 12m, speed 0.0m/s';
      final scrubbed = CrashReporting.scrubLocation(line);

      expect(scrubbed, isNot(contains('19.2358216')));
      expect(scrubbed, isNot(contains('73.1308101')));
      // What went wrong survives. A report that says only "[removed]" is not
      // worth sending.
      expect(scrubbed, contains('accuracy 12m'));
      expect(scrubbed, contains('FIX'));
    });

    test('a LatLng from a package error is emptied, not deleted', () {
      const line =
          'Geofencing error: cannot register region kalyan at '
          'LatLng(19.2358216, 73.1308101)';
      final scrubbed = CrashReporting.scrubLocation(line);

      expect(scrubbed, isNot(contains('19.2358216')));
      expect(scrubbed, contains('cannot register region'));
      expect(scrubbed, contains('LatLng([location removed])'));
    });

    test('a bare pair with no label is still a position', () {
      // The shape a stack trace prints when a record or a list is dumped.
      const line = 'Bad state: no fix near 19.0173761, 72.8430265';
      final scrubbed = CrashReporting.scrubLocation(line);

      expect(scrubbed, isNot(contains('19.0173761')));
      expect(scrubbed, isNot(contains('72.8430265')));
      expect(scrubbed, contains('Bad state'));
    });

    test('ORDINARY NUMBERS SURVIVE, or every report becomes unreadable', () {
      // A scrubber that eats version numbers, durations and accuracies is a
      // scrubber that gets switched off. These are all lines this app logs.
      const lines = [
        'PULSE every 45s, with vibration',
        'WAKE rung 3 of 5, volume 0.8',
        '16 min since the last station, median segment 4 min',
        'Ladder stood down after 12.5 seconds',
        'Android 11, app 1.0.3+7',
      ];
      for (final line in lines) {
        expect(CrashReporting.scrubLocation(line), line, reason: line);
        expect(CrashReporting.looksLikeLocation(line), isFalse, reason: line);
      }
    });

    test('every labelled form the codebase uses', () {
      for (final line in const [
        'lat 19.2358216',
        'lat: 19.2358216',
        'lat=19.2358216',
        'latitude 19.2358216',
        'lng 73.1308101',
        'longitude 73.1308101',
        'LAT 19.2358216',
      ]) {
        expect(
          CrashReporting.scrubLocation(line),
          isNot(contains('19.2358216')),
          reason: line,
        );
        expect(CrashReporting.looksLikeLocation(line), isTrue, reason: line);
      }
    });

    test('a negative coordinate is a coordinate', () {
      // Mumbai is not at a negative latitude, but the scrubber must not be the
      // reason a future line survives. Nothing about this rule is city
      // specific.
      const line = 'FIX lat -33.8688, lng 151.2093';
      final scrubbed = CrashReporting.scrubLocation(line);
      expect(scrubbed, isNot(contains('33.8688')));
      expect(scrubbed, isNot(contains('151.2093')));
    });

    test('scrubbing twice changes nothing more', () {
      const line = 'FIX lat 19.2358216, lng 73.1308101, accuracy 12m';
      final once = CrashReporting.scrubLocation(line);
      expect(CrashReporting.scrubLocation(once), once);
    });
  });

  group('configuration', () {
    test('NO DSN IN THE CHECKOUT, and off is a valid state', () {
      // The repository is public. The DSN arrives through
      // --dart-define-from-file at build time, so a clone, a CI run and every
      // test here must find crash reporting disabled and the app working.
      expect(CrashReporting.dsn, isEmpty);
      expect(CrashReporting.isEnabled, isFalse);
    });

    test('a disabled reporter comes up and does nothing', () async {
      // With no DSN this must return without touching the SDK at all, which is
      // what every clone, every test and every keyless build gets.
      await CrashReporting.startUiIsolate();
      expect(CrashReporting.isEnabled, isFalse);
      expect(
        CrashReporting.uiInitState,
        'not started',
        reason: 'a keyless build must not even claim to have tried',
      );
    });

    test('THE TEST BUTTON MAY NOT BLAME THE DSN FOR A FAILED INIT', () async {
      // 10 Aug 2026: the iPhone opened with a real DSN compiled in and answered
      // "Sentry rejected the event. Check the DSN", which pointed at the one
      // thing that was provably right, since the same DSN was reporting from
      // Android that evening. An empty event id means the SDK is not up.
      final message = await CrashReporting.sendTestEvent();

      // This checkout has no DSN, so it must say exactly that and nothing about
      // rejection.
      expect(message, contains('no DSN in this build'));

      // Read the source for the branch a keyed build takes, because reaching it
      // here would need a live SDK and a network.
      final source = File(
        'lib/services/crash_reporting.dart',
      ).readAsStringSync();
      final body = source.substring(
        source.indexOf('Future<String> sendTestEvent'),
      );
      final method = body.substring(0, body.indexOf('\n  }'));
      expect(
        method,
        contains('uiInitState'),
        reason: 'an empty id must report WHY the SDK is not up',
      );
      expect(
        method,
        isNot(contains('Check the DSN')),
        reason: 'a failed init and a wrong DSN are different faults',
      );
    });
  });

  group('CRASH REPORTING MAY NEVER HOLD THE FIRST FRAME', () {
    // THE 10 AUG 2026 WHITE SCREEN. The first IPA built with a real DSN never
    // reached the home screen on iOS, because Sentry used to wrap runApp in its
    // appRunner and `Sentry._init` awaits EVERY integration before calling it,
    // with no timeout. One of them, on iOS, never returned. Android was fine and
    // a DSN-less build opened instantly, which is what named the culprit.
    //
    // Read from the source, because the invariant is an ORDER of two statements
    // in main(), and there is no way to assert that by running main() in a test:
    // runApp needs a binding, and a hanging integration would hang the test the
    // same way it hung the phone.

    test('main() calls runApp BEFORE it starts crash reporting', () {
      final main = _mainFunction();
      final runApp = main.indexOf('runApp(');
      final sentry = main.indexOf('CrashReporting.startUiIsolate()');

      expect(runApp, isNonNegative, reason: 'main() must run the app');
      expect(sentry, isNonNegative, reason: 'main() must start reporting');
      expect(
        runApp,
        lessThan(sentry),
        reason: 'the app must be drawing before Sentry is allowed to try',
      );
    });

    test('main() never awaits crash reporting, and never wraps the app', () {
      final main = _mainFunction();
      expect(
        main,
        matches(RegExp(r'unawaited\(\s*CrashReporting\.startUiIsolate\(')),
        reason: 'awaiting it would restore the hang',
      );
      // The exact shape of the old bug: any callback handed to crash reporting
      // is an appRunner by another name.
      expect(
        main,
        isNot(contains('CrashReporting.runUiIsolate')),
        reason: 'appRunner is what held the first frame',
      );
      expect(main, isNot(matches(RegExp(r'await\s+CrashReporting\.'))));
    });

    test('the guard can still fail', () {
      // Per the twice-learned lesson about guards nobody has seen fail. These
      // are the two orderings the real bug had, checked against the same
      // assertions the test above makes.
      const broken = '''
void main() {
  CrashReporting.runUiIsolate(() {
    runApp(const ProviderScope(child: App()));
  });
}''';
      expect(broken, contains('CrashReporting.runUiIsolate'));
      expect(
        broken.indexOf('runApp('),
        greaterThan(broken.indexOf('CrashReporting.runUiIsolate')),
        reason: 'the old code must fail the ordering assertion',
      );

      const awaited = '''
void main() async {
  runApp(const ProviderScope(child: App()));
  await CrashReporting.startUiIsolate();
}''';
      expect(
        awaited,
        isNot(
          matches(RegExp(r'unawaited\(\s*CrashReporting\.startUiIsolate\(')),
        ),
        reason: 'an awaited init must fail the unawaited assertion',
      );
    });
  });
}

/// The body of `main()` in lib/main.dart, comments stripped.
///
/// Comments are removed because this file's own explanation has to name
/// `runUiIsolate` and `appRunner`, which are the very strings the guard forbids.
/// That is the third time this project has made that mistake, so it is now the
/// default assumption when a guard reads source.
String _mainFunction() {
  final source = File('lib/main.dart').readAsStringSync();
  final start = source.indexOf('void main()');
  expect(start, isNonNegative, reason: 'main() must exist');
  final body = source.substring(start, source.indexOf('\n}', start));
  return body
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment == -1 ? line : line.substring(0, comment);
      })
      .join('\n');
}
