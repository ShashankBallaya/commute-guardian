import 'package:commute_guardian/services/ride_resume.dart';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

/// Resuming a ride the OS killed.
///
/// THE 16 AUG EXIT RIDE IS THE CASE. iOS jetsammed the app mid-journey and
/// told nobody, and the app could not tell that apart from a rider who had
/// finished, because the only question it asked was "is a ride running now".
///
/// Every test here reproduces the kill AT THE DESK, which is the point of
/// keeping the decision pure: a jetsam is a state, not an event, and the state
/// is two booleans and a timestamp.
void main() {
  /// The store as the dead service left it: a ride in flight, no service.
  PersistedRide killed({
    String? originId = 'shahad',
    String? destinationId = 'csmt',
    DateTime? startedAt,
    // Separate from a null [startedAt], which the default fills in. This is how
    // a test says the key is MISSING.
    bool noStartedAt = false,
    bool rideInFlight = true,
    bool destinationReached = false,
    int reachedIndex = 11,
    int? startBatteryPct = 74,
  }) => PersistedRide(
    originId: originId,
    destinationId: destinationId,
    destinationReached: destinationReached,
    reachedIndex: reachedIndex,
    startedAt: noStartedAt ? null : startedAt ?? DateTime(2026, 8, 16, 19, 30),
    startBatteryPct: startBatteryPct,
    rideInFlight: rideInFlight,
  );

  final now = DateTime(2026, 8, 16, 20, 15);

  group('interruptedRideFrom', () {
    test('a killed ride is offered back, with the ride it was', () {
      final ride = interruptedRideFrom(
        killed(),
        serviceRunning: false,
        now: now,
      );

      expect(ride, isNotNull);
      expect(ride!.originId, 'shahad');
      expect(ride.destinationId, 'csmt');
      // The ORIGINAL start, never now(). It is what the history row is written
      // from, and what stops a second kill handing the same ride a fresh three
      // hours every time it is picked up.
      expect(ride.startedAt, DateTime(2026, 8, 16, 19, 30));
      expect(ride.startBatteryPct, 74);
      expect(ride.reachedIndex, 11);
    });

    test('a running ride is not an interrupted one', () {
      // The discriminator's other half. liveRideProvider owns this case, and
      // offering to resume it would start a second service beside the first.
      expect(
        interruptedRideFrom(killed(), serviceRunning: true, now: now),
        isNull,
      );
    });

    test('a ride the rider ended is not offered back', () {
      // onDestroy ran, which is exactly what the flag records. This is the
      // ordinary end of every healthy journey and it must stay silent.
      expect(
        interruptedRideFrom(
          killed(rideInFlight: false),
          serviceRunning: false,
          now: now,
        ),
        isNull,
      );
    });

    test('a ride that reached its destination is over, however it ended', () {
      // The rider was told they had arrived. Whatever happened next, an alarm
      // for this journey would be noise, and noise is what teaches riders to
      // ignore the voice.
      expect(
        interruptedRideFrom(
          killed(destinationReached: true),
          serviceRunning: false,
          now: now,
        ),
        isNull,
      );
    });

    test('the offer expires, so this morning is not offered at dinner', () {
      final started = now.subtract(resumeWindow).subtract(
        const Duration(minutes: 1),
      );
      expect(
        interruptedRideFrom(
          killed(startedAt: started),
          serviceRunning: false,
          now: now,
        ),
        isNull,
      );
    });

    test('a ride inside the window survives, right up to the edge', () {
      final started = now.subtract(resumeWindow);
      expect(
        interruptedRideFrom(
          killed(startedAt: started),
          serviceRunning: false,
          now: now,
        ),
        isNotNull,
      );
    });

    test('a ride dated into the future is not trusted', () {
      // A clock change, not a journey. We cannot claim to know this ride is
      // still happening, so we do not.
      expect(
        interruptedRideFrom(
          killed(startedAt: now.add(const Duration(minutes: 5))),
          serviceRunning: false,
          now: now,
        ),
        isNull,
      );
    });

    test('a flag with no ride behind it offers nothing', () {
      // A store race or a half-cleared key. Resuming it would start a service
      // with nowhere to go.
      for (final incomplete in [
        killed(originId: null),
        killed(destinationId: null),
        killed(noStartedAt: true),
      ]) {
        expect(
          interruptedRideFrom(incomplete, serviceRunning: false, now: now),
          isNull,
        );
      }
    });

    test('a store with no ride at all is silent', () {
      expect(
        interruptedRideFrom(
          const PersistedRide(
            originId: null,
            destinationId: null,
            destinationReached: false,
          ),
          serviceRunning: false,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('interruptedRideProvider', () {
    ProviderContainer makeContainer(FakeRideServiceClient service) {
      final container = ProviderContainer(
        overrides: [rideServiceClientProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reads the killed ride back at launch', () async {
      final c = makeContainer(
        FakeRideServiceClient(
          running: false,
          rideInFlight: true,
          originId: 'shahad',
          destinationId: 'csmt',
          startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
        ),
      );

      final ride = await c.read(interruptedRideProvider.future);
      expect(ride, isNotNull);
      expect(ride!.destinationId, 'csmt');
    });

    test('a killed ride does NOT make the app think it is on a ride', () async {
      // THE LOAD-BEARING SEPARATION. isRideRunningProvider drives Screen 4, the
      // ride notification and the alert routing. A dead ride lighting those up
      // is the exact failure this was built to make visible.
      final c = makeContainer(
        FakeRideServiceClient(
          running: false,
          rideInFlight: true,
          originId: 'shahad',
          destinationId: 'csmt',
          startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
        ),
      );

      expect(await c.read(interruptedRideProvider.future), isNotNull);
      expect(await c.read(liveRideProvider.future), isNull);
      expect(c.read(isRideRunningProvider), isFalse);
    });

    test('an ordinary launch with no ride offers nothing', () async {
      final c = makeContainer(FakeRideServiceClient(running: false));
      expect(await c.read(interruptedRideProvider.future), isNull);
    });

    test('declining forgets the ride, so it is asked once', () async {
      final service = FakeRideServiceClient(
        running: false,
        rideInFlight: true,
        originId: 'shahad',
        destinationId: 'csmt',
        startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
      );
      final c = makeContainer(service);
      expect(await c.read(interruptedRideProvider.future), isNotNull);

      await c.read(interruptedRideProvider.notifier).dismiss();

      expect(c.read(interruptedRideProvider).valueOrNull, isNull);
      expect(service.commands, contains('clearRideInFlight'));
      // And the STORE agrees, not only this notifier: the next launch reads the
      // store, not the object a dismissed screen was holding.
      await c.read(interruptedRideProvider.notifier).refresh();
      expect(c.read(interruptedRideProvider).valueOrNull, isNull);
    });

    test('ending the ride is what forgets it, not the service dying', () async {
      // THE 17 AUG 2026 BENCH MOVED THIS RULE. The flag used to be cleared in
      // the service's onDestroy, and both killed rides in that bench proved
      // onDestroy is the wrong place twice over: iOS runs it on a swipe-away,
      // which is not a rider ending anything, and it killed the process inside
      // the 2.5 s farewell that the write sat behind. The offer appeared
      // because the write was unreachable. That is luck, and a shorter farewell
      // would have turned the feature off with nothing to show for it.
      //
      // So the clearing moved to the endings somebody CHOOSES, and End journey
      // is the one a rider presses.
      final service = FakeRideServiceClient(
        running: true,
        rideInFlight: true,
        originId: 'shahad',
        destinationId: 'titwala',
        startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      final c = makeContainer(service);
      // Running, so nothing is offered yet whatever the flag says.
      expect(await c.read(interruptedRideProvider.future), isNull);

      await service.stopRide();

      expect(service.rideInFlight, isFalse);
      await c.read(interruptedRideProvider.notifier).refresh();
      expect(
        c.read(interruptedRideProvider).valueOrNull,
        isNull,
        reason: 'a ride the rider ended must never be offered back',
      );
    });

    test('no service plumbing means no offer, never a crash', () async {
      // Widget tests and the real client with no plugin both land here.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(await c.read(interruptedRideProvider.future), isNull);
    });
  });
}
