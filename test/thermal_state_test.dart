import 'dart:io';

import 'package:commute_guardian/services/thermal_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// The thermal instrument, and the reason it exists.
///
/// The 16 Aug 2026 crash report is the ONLY thermal reading this project has
/// ever had: `Thermal Level: 7, Thermal State: serious`, taken at the moment
/// iOS killed a ride. Nobody knows what a normal ride looks like, or whether
/// the phone is already "serious" by the time the wake ladder fires.
void main() {
  group('the platform words, in order', () {
    test('the order IS the meaning, because a log has to say "it climbed"', () {
      expect(ThermalState.values.map((s) => s.name), [
        'nominal',
        'fair',
        'serious',
        'critical',
      ]);
      expect(ThermalState.serious.index, greaterThan(ThermalState.fair.index));
    });

    test('raw values match iOS ProcessInfo.ThermalState, 0 to 3', () {
      // The Swift side sends rawValue, not a word, so this mapping is the whole
      // contract across the boundary. Getting it wrong would silently report a
      // cool phone as hot.
      expect(ThermalState.fromRaw(0), ThermalState.nominal);
      expect(ThermalState.fromRaw(1), ThermalState.fair);
      expect(ThermalState.fromRaw(2), ThermalState.serious);
      expect(ThermalState.fromRaw(3), ThermalState.critical);
    });

    test('ANYTHING ELSE IS NO READING, never a guess', () {
      // A platform that will not answer, an older store, a future fifth level
      // Apple adds. All of them mean the same thing: we do not know.
      expect(ThermalState.fromRaw(null), isNull);
      expect(ThermalState.fromRaw(-1), isNull);
      expect(ThermalState.fromRaw(4), isNull);
      expect(ThermalState.fromRaw(99), isNull);
    });
  });

  group('IT CANNOT FAIL INTO A RIDE', () {
    test('a platform with no handler answers null, it does not throw', () async {
      // No test binding answers this channel, which is exactly the situation on
      // Android today and on any platform that never wires it up. The service
      // isolate calls this on a timer, and an unhandled error there is the
      // failure this project fears most: the isolate whose death is silent.
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await const ThermalGateway().read(), isNull);
    });

    test('NO PLATFORM ALLOW-LIST, which is the bug this project keeps having', () {
      // Five guards in this repo have been wrong by naming platforms instead of
      // stating a constraint. Android gained a thermal API at SDK 29 and the 3T
      // is 28; a Platform.isIOS check here would quietly exclude the day
      // somebody wires it up. A missing handler already answers null.
      final source = File(
        'lib/services/thermal_gateway.dart',
      ).readAsStringSync();
      final code = source
          .split('\n')
          .where((line) {
            final trimmed = line.trimLeft();
            return !trimmed.startsWith('//') && !trimmed.startsWith('///');
          })
          .join('\n');
      expect(code, isNot(contains('Platform.is')));
    });
  });

  group('THE RIDE LOG RECORDS CHANGES, NOT A HEARTBEAT', () {
    final source = File(
      'lib/services/geofence_chain_service.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final body = source.substring(
      source.indexOf('void _noteThermalState(DateTime now) {'),
      source.indexOf('\n  void onTick('),
    );

    test('it returns early when the state has not changed', () {
      expect(body, contains('state == _lastThermal'));
    });

    test('AND IT IS NEVER AWAITED ON THE TICK', () {
      // The tick drives the wake ladder, the pulse and the wind-down. An
      // instrument may not stand in front of any of them.
      expect(body, contains('unawaited('));
    });

    test('it asks at most once a minute', () {
      expect(body, contains('_thermalInterval'));
      expect(
        source,
        contains('static const _thermalInterval = Duration(seconds: 60);'),
      );
    });
  });
}
