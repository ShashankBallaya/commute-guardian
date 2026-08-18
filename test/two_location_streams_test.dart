import 'dart:io';

import 'package:commute_guardian/services/geofence_chain_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// THIS APP OPENS TWO LOCATION STREAMS FOR EVERY RIDE, and until 18 Aug 2026
/// nobody had noticed.
///
/// Ours runs at navigation accuracy every 1000 ms and feeds RideProgress, which
/// is the single source of every spoken announcement. `geofencing_api` opens a
/// SECOND one, also at navigation accuracy, at its default 5000 ms. Its start()
/// is pure Dart, so this happens on iOS as well as Android, on the platform
/// that gets killed for being slow.
///
/// The second stream's only surviving output is one `ENTER ... (native)` log
/// line per station, kept for native-versus-backstop comparison. The native
/// ENTER stopped speaking when RideProgress took over.
///
/// This file does not argue for removing it. It pins the FACTS, so the decision
/// is made against a bench number and not against a memory of how the ride
/// engine used to work.
void main() {
  final source = File(
    'lib/services/geofence_chain_service.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  String withoutComments(String code) => code
      .split('\n')
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//') && !trimmed.startsWith('///');
      })
      .join('\n');

  group('the two streams, and which one speaks', () {
    test('OUR stream is 1 Hz at navigation accuracy', () {
      final code = withoutComments(source).replaceAll(RegExp(r'\s+'), ' ');
      expect(code, contains('fl.FlLocation.getLocationStream('));
      expect(code, contains('accuracy: fl.LocationAccuracy.navigation'));
      expect(code, contains('interval: 1000'));
    });

    test('AND IT IS THE ONE THAT SPEAKS', () {
      // If this ever stops being true, the flag below stops being safe: turning
      // the native engine off would take the announcements with it.
      final code = withoutComments(source);
      final start = code.indexOf('Future<void> _onRawLocation(');
      expect(start, greaterThan(-1), reason: 'the raw handler is gone');
      // A window rather than a delimiter: the handler is long and the next
      // member's signature is not a stable landmark.
      expect(
        code.substring(start, start + 2000),
        contains('_rideProgress?.onFix('),
        reason: 'the raw stream feeds RideProgress, which is what announces',
      );
    });

    test('the native ENTER only logs, it does not announce', () {
      final code = withoutComments(source);
      final start = code.indexOf('final station = chain[index];');
      final body = code.substring(start, code.indexOf('\n  Future<void> _onRawLocation('));
      expect(body, contains('(native)'));
      expect(
        body,
        isNot(contains('_speak(')),
        reason: 'RideProgress became the single source; this is diagnostics',
      );
    });
  });

  group('the bench flag', () {
    test('defaults OFF, so an ordinary build is unchanged', () {
      expect(GeofenceChainService.nativeGeofenceEngineOff, isFalse);
    });

    test('IT IS A dart-define, NOT A SETTING A RIDER CAN REACH', () {
      // A bench flag a rider can reach is a bench flag that will one day be on
      // during a real ride.
      expect(
        source.replaceAll(RegExp(r'\s+'), ' '),
        contains("bool.fromEnvironment( 'NATIVE_GEOFENCE_OFF', )"),
      );
    });

    test('it guards the START, the LISTENERS and the STOP', () {
      // Missing the stop would leave a stream running after a ride ends, which
      // is the opposite of what this flag is for.
      final code = withoutComments(source);
      expect(code, contains('if (nativeGeofenceEngineOff) {'));
      expect(
        RegExp(r'if \(!nativeGeofenceEngineOff\) \{').allMatches(code).length,
        2,
        reason: 'the listener setup and the teardown are both guarded',
      );
    });
  });
}
