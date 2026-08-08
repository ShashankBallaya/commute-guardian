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

    test('a disabled reporter still runs the app', () async {
      var ran = false;
      await CrashReporting.runUiIsolate(() => ran = true);
      expect(ran, isTrue);
    });
  });
}
