import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/state/ride_providers.dart';

import 'support/fake_ride_service_client.dart';

/// THE ALARM TAKES THE MEDIA VOLUME ON iOS, and gives it back.
///
/// Owner decision, 13 Aug 2026, taken from a measurement rather than a
/// preference: the Bench B Part 2 log opens with "Alarm volume at start: 0%"
/// and the whole wake ladder ran its course in silence. iOS has no alarm
/// stream, so the ladder plays at whatever the media slider says. It is the
/// third time his phone has done this.
///
/// Android needs none of it and must never get it: the tone rides STREAM_ALARM
/// and the media slider cannot touch it. That guard lives in the client, which
/// is why these tests drive the notifier and not the platform.
void main() {
  late ProviderContainer container;
  late FakeRideServiceClient service;

  setUp(() {
    service = FakeRideServiceClient();
    container = ProviderContainer(
      overrides: [rideServiceClientProvider.overrideWithValue(service)],
    );
    // Builds the notifier so it subscribes to the service's event stream, the
    // same way the app does at launch.
    container.read(rideAlertsProvider);
    addTearDown(container.dispose);
  });

  /// Delivers a service event and lets the notifier's async work finish.
  Future<void> emit(ServiceEvent event) async {
    service.emit(event);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'an armed ladder asks for the volume, and stand-down gives it back',
    () async {
      service.raisedFrom = 0.0; // the rider's slider was at zero
      await emit(const WakeLadderChanged(true));
      await emit(const WakeLadderChanged(false));

      expect(service.commands, contains('raiseAlarmVolume:0.7'));
      expect(
        service.commands,
        contains('restoreAlarmVolume:0.0'),
        reason: 'the rider gets their own volume back, not a guess at it',
      );
    },
  );

  test('A RIDER ALREADY LOUD ENOUGH IS LEFT COMPLETELY ALONE', () async {
    // raiseAlarmVolume returns null when it changed nothing, and a null must
    // never become a restore: putting back a volume we did not take is its own
    // way of moving someone's slider behind their back.
    service.raisedFrom = null;
    await emit(const WakeLadderChanged(true));
    await emit(const WakeLadderChanged(false));

    expect(service.commands, contains('raiseAlarmVolume:0.7'));
    expect(
      service.commands.where((c) => c.startsWith('restoreAlarmVolume')),
      isEmpty,
      reason:
          'no call at all, not a call with a null. We never move a slider we '
          'did not move in the first place',
    );
  });

  test(
    'A LADDER RE-ARMING AFTER A CALL DOES NOT FORGET THE REAL VOLUME',
    () async {
      // The 13 Aug bench took two calls during one ladder. Each hang-up re-arms
      // the ladder, and a second raise that overwrote the remembered volume with
      // the one WE set would hand the rider back 70 percent forever.
      service.raisedFrom = 0.0;
      await emit(const WakeLadderChanged(true));

      // The call, then the hang-up: stood down and armed again.
      service.raisedFrom =
          0.7; // what the slider reads now, because we raised it
      await emit(const WakeLadderChanged(true, rung: 1));
      await emit(const WakeLadderChanged(false));

      expect(
        service.commands,
        contains('restoreAlarmVolume:0.0'),
        reason: 'the remembered volume is the one from BEFORE the first raise',
      );
      expect(
        service.commands,
        isNot(contains('restoreAlarmVolume:0.7')),
        reason:
            'restoring our own raise would leave the phone permanently loud',
      );
    },
  );

  test('A RIDE TORN DOWN MID-ALARM STILL RESTORES THE VOLUME', () async {
    // standDown() is the teardown path: a force-stop, a swipe, a service that
    // died. Leaving the phone at a volume the rider never chose is the one
    // side effect this feature must not have.
    service.raisedFrom = 0.1;
    await emit(const WakeLadderChanged(true));
    await container.read(rideAlertsProvider.notifier).standDown();

    expect(service.commands, contains('restoreAlarmVolume:0.1'));
  });
}
