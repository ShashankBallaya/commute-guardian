import 'package:commute_guardian/services/ride_resume.dart';
import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/station.dart';
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

  group('STILL ON THIS JOURNEY, OR NOT', () {
    // The evidence test for an UNATTENDED resume. Given iOS relaunching the app
    // because the phone moved, this is what decides whether the ride restarts
    // without asking. Measured against the real generated station data, because
    // a corridor test built on invented coordinates proves only arithmetic.
    late StationRepository repo;

    setUpAll(() {
      repo = StationRepository.parse(
        File(StationRepository.assetPath).readAsStringSync(),
      );
    });

    List<Station> chain(List<String> ids) =>
        [for (final id in ids) repo.stationsById[id]!];

    // THE RIDE THAT DIED ON 16 AUG 2026, and EVERY station on it.
    //
    // Density matters, and the first draft of this test proved it by being
    // wrong. With a sparse chain (CSMT, Dadar, Kurla, Thane, Dombivli, Kalyan)
    // the segments are long straight lines that cut across geography, and Powai
    // came out 1.26 km from the "corridor" while being nowhere near a railway.
    // A planned chain always holds every station, so the segments hug the
    // track. A test that skips them measures a corridor the app never uses.
    final homeward = [
      'csmt', 'masjid', 'sandhurst_road', 'byculla', 'chinchpokli',
      'currey_road', 'parel', 'dadar', 'matunga', 'sion', 'kurla',
      'vidyavihar', 'ghatkopar', 'vikhroli', 'kanjurmarg', 'bhandup', 'nahur',
      'mulund', 'thane', 'mumbra', 'diva', 'kopar', 'dombivli', 'thakurli',
      'kalyan', 'shahad',
    ];

    test('a train BETWEEN two stations is on the corridor, not lost', () {
      // THE REASON THIS MEASURES SEGMENTS AND NOT STATIONS. Thane to Mumbra is
      // the longest hop on this chain at 4983 m, so its midpoint is 2492 m from
      // either station, well past the tolerance, while being exactly where a
      // rider is supposed to be. Measuring to stations would call that rider
      // lost and refuse to give them their ride back.
      final stations = chain(homeward);
      final thane = repo.stationsById['thane']!;
      final mumbra = repo.stationsById['mumbra']!;
      final midLat = (thane.lat + mumbra.lat) / 2;
      final midLng = (thane.lng + mumbra.lng) / 2;

      expect(
        thane.distanceM(midLat, midLng),
        greaterThan(corridorToleranceM),
        reason: 'the nearest STATION is far away, which is the whole point',
      );
      expect(distanceToCorridorM(stations, midLat, midLng), lessThan(500));
      expect(
        mayResumeUnattended(
          chain: stations,
          lat: midLat,
          lng: midLng,
          accuracyM: 0,
        ),
        isTrue,
      );
    });

    test('a rider standing IN a station on the chain is on the corridor', () {
      final stations = chain(homeward);
      final kurla = repo.stationsById['kurla']!;
      expect(distanceToCorridorM(stations, kurla.lat, kurla.lng), lessThan(1));
    });

    test('A RIDER WHO WENT HOME ANOTHER WAY GETS NOTHING', () {
      // The failure this exists to prevent: announcing stations, and eventually
      // an alarm, to somebody who left the railway and took a rickshaw.
      // Andheri is on the Western line, 6 km off this chain, and is a real
      // place a Mumbai commuter ends up.
      final stations = chain(homeward);
      final andheri = repo.stationsById['andheri']!;
      expect(
        distanceToCorridorM(stations, andheri.lat, andheri.lng),
        greaterThan(corridorToleranceM),
      );
      expect(
        mayResumeUnattended(
          chain: stations,
          lat: andheri.lat,
          lng: andheri.lng,
          accuracyM: 0,
        ),
        isFalse,
      );
    });

    test('A COARSE FIX WIDENS THE QUESTION, it does not answer it', () {
      // The fix that relaunches the app comes from cell and wifi positioning,
      // where several hundred metres of error is normal. That must not read as
      // "this rider is lost", so accuracy is ADDED to the tolerance.
      final stations = chain(homeward);
      final andheri = repo.stationsById['andheri']!;
      final off = distanceToCorridorM(stations, andheri.lat, andheri.lng)!;

      expect(
        mayResumeUnattended(
          chain: stations,
          lat: andheri.lat,
          lng: andheri.lng,
          accuracyM: off,
        ),
        isTrue,
        reason: 'a fix this uncertain cannot prove the rider left the line',
      );
      // And it is not unbounded: a fix must still be roughly where it claims.
      expect(
        mayResumeUnattended(
          chain: stations,
          lat: andheri.lat,
          lng: andheri.lng,
          accuracyM: 100,
        ),
        isFalse,
      );
    });

    test('a chain too short to have a corridor refuses, it does not guess', () {
      expect(distanceToCorridorM(chain(['kalyan']), 19.24, 73.15), isNull);
      expect(
        mayResumeUnattended(
          chain: chain(['kalyan']),
          lat: 19.24,
          lng: 73.15,
          accuracyM: 0,
        ),
        isFalse,
        reason: 'no corridor means no evidence, and no evidence means ask',
      );
    });

    test('a station on the chain but ALREADY PASSED is still on it', () {
      // Deliberate. This test answers "is the rider still on this journey",
      // never "are they where they should be". A train held at Mumbra on the
      // way to Kalyan is on the corridor, and so is one that overshot. Where
      // they are along the chain is RideProgress's job, and it localizes
      // itself on the first fix.
      final stations = chain(homeward);
      final mumbra = repo.stationsById['mumbra']!;
      expect(
        mayResumeUnattended(
          chain: stations,
          lat: mumbra.lat,
          lng: mumbra.lng,
          accuracyM: 0,
        ),
        isTrue,
      );
    });
  });
}
