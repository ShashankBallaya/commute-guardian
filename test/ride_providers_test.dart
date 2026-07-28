import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

/// The running-ride half of the state model, driven by scripted service
/// events with no widget in sight.
void main() {
  ProviderContainer makeContainer(FakeRideServiceClient service) {
    final container = ProviderContainer(
      overrides: [rideServiceClientProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('liveRideProvider', () {
    test('reads the running ride from the store, with nothing else asked', () async {
      final service = FakeRideServiceClient(
        running: true,
        originId: 'kalyan',
        destinationId: 'thane',
        destinationReached: true,
      );
      final c = makeContainer(service);

      final ride = await c.read(liveRideProvider.future);
      expect(ride, isNotNull);
      expect(ride!.originId, 'kalyan');
      expect(ride.destinationId, 'thane');
      expect(ride.destinationReached, isTrue);
      expect(c.read(isRideRunningProvider), isTrue);
    });

    test('no service running means no ride, not an empty one', () async {
      final c = makeContainer(FakeRideServiceClient(running: false));
      expect(await c.read(liveRideProvider.future), isNull);
      expect(c.read(isRideRunningProvider), isFalse);
    });

    test('a running service with no ids in the store reports no ride', () async {
      // A store race, not a ride. Reporting no ride is the safe read: the
      // screen falls back to the normal GPS origin fill.
      final c = makeContainer(FakeRideServiceClient(running: true));
      expect(await c.read(liveRideProvider.future), isNull);
    });

    test('the service ending the ride on its own clears the projection', () async {
      final service = FakeRideServiceClient(
        running: true,
        originId: 'kalyan',
        destinationId: 'thane',
      );
      final c = makeContainer(service);
      expect(await c.read(liveRideProvider.future), isNotNull);

      // Wind-down auto-off: the service stops itself and announces it. Without
      // the subscription this projection would stay frozen and the screen
      // would go on claiming a ride that had stopped.
      service.running = false;
      service.emit(const RideEndedByService());
      await Future<void>.delayed(Duration.zero);

      expect(c.read(liveRideProvider).valueOrNull, isNull);
      expect(c.read(isRideRunningProvider), isFalse);
    });
  });

  group('rideAlertsProvider', () {
    test('reduces a scripted event sequence, and each flag moves alone', () async {
      final service = FakeRideServiceClient();
      final c = makeContainer(service);
      // Reading it first is what subscribes it, see the note below.
      expect(c.read(rideAlertsProvider).wakeLadderLive, isFalse);

      service.emit(const WakeLadderChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(rideAlertsProvider).wakeLadderLive, isTrue);
      expect(c.read(rideAlertsProvider).windDownLive, isFalse);

      service.emit(const WindDownChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(rideAlertsProvider).wakeLadderLive, isTrue,
          reason: 'wind-down must not clear the ladder');
      expect(c.read(rideAlertsProvider).windDownLive, isTrue);

      service.emit(const WakeLadderChanged(false));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(rideAlertsProvider).wakeLadderLive, isFalse);
      expect(c.read(rideAlertsProvider).windDownLive, isTrue);
    });

    test('a live ladder claims the media session, and releases it after', () async {
      final service = FakeRideServiceClient();
      final c = makeContainer(service);
      c.read(rideAlertsProvider);

      service.emit(const WakeLadderChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(service.commands, contains('setMediaSession:true'));

      // Outside a ladder the rider's earphone taps must go back to their music.
      service.emit(const WakeLadderChanged(false));
      await Future<void>.delayed(Duration.zero);
      expect(service.commands, contains('setMediaSession:false'));
    });

    test('a tone command is forwarded to native with its volume', () async {
      final service = FakeRideServiceClient();
      final c = makeContainer(service);
      c.read(rideAlertsProvider);

      service.emit(const ToneCommanded('startTone', 0.3));
      await Future<void>.delayed(Duration.zero);
      expect(service.commands, contains('tone:startTone:0.3'));
    });

    test('standing down clears both flags and drops the media session', () async {
      final service = FakeRideServiceClient();
      final c = makeContainer(service);
      // Read first. The notifier is lazy, so it does not subscribe until
      // someone asks for it, and events emitted before that are simply
      // missed. This is why the screen reads it in initState rather than
      // waiting for its first build.
      c.read(rideAlertsProvider);
      service.emit(const WakeLadderChanged(true));
      service.emit(const WindDownChanged(true));
      await Future<void>.delayed(Duration.zero);
      service.commands.clear();

      await c.read(rideAlertsProvider.notifier).standDown();

      expect(c.read(rideAlertsProvider).wakeLadderLive, isFalse);
      expect(c.read(rideAlertsProvider).windDownLive, isFalse);
      // The dying service announces this too, but a teardown race must not
      // leave a claimed media session behind.
      expect(service.commands, contains('setMediaSession:false'));
    });

    test('standing down with no ladder live does not touch the media session',
        () async {
      final service = FakeRideServiceClient();
      final c = makeContainer(service);
      c.read(rideAlertsProvider);

      await c.read(rideAlertsProvider.notifier).standDown();
      expect(service.commands, isEmpty);
    });
  });
}
