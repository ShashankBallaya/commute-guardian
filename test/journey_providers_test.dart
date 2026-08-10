import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pre-ride state model, tested without a widget.
///
/// All of this behaviour existed before the Riverpod migration, buried in
/// _RideDebugScreenState where the only way to reach it was to pump a screen
/// and tap. These are the same rules, now assertable directly.
void main() {
  late StationRepository repo;

  setUpAll(() {
    // Straight off disk rather than through rootBundle: the asset bundle does
    // real I/O, which cannot make progress inside a fake-async zone.
    repo = StationRepository.parse(
      File(StationRepository.assetPath).readAsStringSync(),
    );
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [stationRepositoryProvider.overrideWith((ref) => repo)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('plannedJourneyProvider', () {
    test('stays empty until both ends are picked', () {
      final c = makeContainer();
      expect(c.read(plannedJourneyProvider).journey, isNull);
      expect(c.read(plannedJourneyProvider).error, isNull);

      c.read(journeyDraftProvider.notifier).setOrigin('kalyan');
      expect(
        c.read(plannedJourneyProvider).journey,
        isNull,
        reason: 'an origin alone is not a journey',
      );
      expect(
        c.read(plannedJourneyProvider).error,
        isNull,
        reason: 'a half-filled draft is not an error, it is unfinished',
      );
    });

    test('plans as soon as both ends exist, and replans on a change', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.setOrigin('kalyan');
      draft.setDestination('thane');

      final planned = c.read(plannedJourneyProvider).journey;
      expect(planned, isNotNull);
      expect(planned!.originStationId, 'kalyan');
      expect(planned.destinationStationId, 'thane');

      // The old widget had to remember to call _replan() after every pick.
      // Derivation cannot forget.
      draft.setDestination('dombivli');
      expect(
        c.read(plannedJourneyProvider).journey!.destinationStationId,
        'dombivli',
      );
    });

    test('a journey to nowhere reports the planner reason, not a crash', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.setOrigin('kalyan');
      draft.setDestination('kalyan');

      final planned = c.read(plannedJourneyProvider);
      expect(planned.journey, isNull);
      expect(planned.error, isNotNull);
    });

    test('clearing an end clears the plan', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.setOrigin('kalyan');
      draft.setDestination('thane');
      expect(c.read(plannedJourneyProvider).journey, isNotNull);

      draft.setDestination(null);
      expect(c.read(plannedJourneyProvider).journey, isNull);
    });
  });

  group('journeyDraft', () {
    test('a GPS fill never overwrites a deliberate pick', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.setOrigin('thane');

      expect(draft.defaultOriginTo('kalyan'), isFalse);
      expect(c.read(journeyDraftProvider).originId, 'thane');
    });

    test('a GPS fill does fill an empty origin', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      expect(draft.defaultOriginTo('kalyan'), isTrue);
      expect(c.read(journeyDraftProvider).originId, 'kalyan');
    });

    test(
      'the turnaround keeps the origin and always clears the destination',
      () {
        final c = makeContainer();
        final draft = c.read(journeyDraftProvider.notifier);
        draft.setOrigin('kalyan');
        draft.setDestination('thane');

        draft.resetAfterRide(originId: 'thane');
        expect(c.read(journeyDraftProvider).originId, 'thane');
        expect(c.read(journeyDraftProvider).destinationId, isNull);
      },
    );

    test(
      'a ride that never arrived leaves the origin empty for the GPS fill',
      () {
        final c = makeContainer();
        final draft = c.read(journeyDraftProvider.notifier);
        draft.setOrigin('kalyan');
        draft.setDestination('thane');

        draft.resetAfterRide();
        expect(c.read(journeyDraftProvider).originId, isNull);
        expect(draft.defaultOriginTo('mumbra'), isTrue);
      },
    );

    test('a fix corrects a turnaround origin the rider never chose', () {
      // The 9 Aug false alarm. A bench ride "arrived" at Shahad, so the
      // turnaround planted Shahad, and the rider was standing at Kalyan.
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.resetAfterRide(originId: 'shahad');

      expect(draft.defaultOriginTo('kalyan'), isTrue);
      expect(c.read(journeyDraftProvider).originId, 'kalyan');
    });

    test(
      'a fix does not replan when it agrees with the origin already there',
      () {
        final c = makeContainer();
        final draft = c.read(journeyDraftProvider.notifier);
        draft.resetAfterRide(originId: 'kalyan');
        final before = c.read(journeyDraftProvider);

        expect(draft.defaultOriginTo('kalyan'), isFalse);
        expect(
          c.read(journeyDraftProvider),
          same(before),
          reason: 'a stationary rider streams fixes; each new draft replans',
        );
      },
    );

    test(
      'Start makes a filled origin the rider own it, and a fix leaves it',
      () {
        final c = makeContainer();
        final draft = c.read(journeyDraftProvider.notifier);
        expect(draft.defaultOriginTo('kalyan'), isTrue);
        draft.confirmOrigin();

        expect(
          draft.defaultOriginTo('thane'),
          isFalse,
          reason: 'otherwise the origin walks along the line behind the train',
        );
        expect(c.read(journeyDraftProvider).originId, 'kalyan');
      },
    );

    test('Start with no origin confirms nothing', () {
      final c = makeContainer();
      final draft = c.read(journeyDraftProvider.notifier);
      draft.confirmOrigin();

      expect(c.read(journeyDraftProvider).originId, isNull);
      expect(draft.defaultOriginTo('kalyan'), isTrue);
    });
  });

  group('nearestStation.applyFix, the one gate for every fix', () {
    test('a good fix names the station and fills the origin', () {
      final c = makeContainer();
      // Kalyan's own coordinates, 13 m accuracy: the median a real ride sees.
      final named = c
          .read(nearestStationProvider.notifier)
          .applyFix(19.2358216, 73.1308101, 13);

      expect(named, isTrue);
      expect(c.read(nearestStationProvider).state, GpsState.located);
      expect(c.read(nearestStationProvider).stationName, 'Kalyan');
      expect(c.read(journeyDraftProvider).originId, 'kalyan');
    });

    test('a vague fix names nothing, because a guess plans the wrong ride', () {
      final c = makeContainer();
      final named = c
          .read(nearestStationProvider.notifier)
          .applyFix(19.2358216, 73.1308101, 501);

      expect(named, isFalse);
      expect(c.read(nearestStationProvider).state, GpsState.unavailable);
      expect(c.read(journeyDraftProvider).originId, isNull);
    });

    test('a fix nowhere near the network admits it rather than guessing', () {
      final c = makeContainer();
      // Precise, and about 200 km inland from the Mumbai suburban network.
      final named = c
          .read(nearestStationProvider.notifier)
          .applyFix(19.0, 75.0, 10);

      expect(named, isFalse);
      expect(c.read(nearestStationProvider).state, GpsState.unavailable);
      expect(c.read(nearestStationProvider).stationName, isNull);
    });

    test(
      'the chip keeps reporting position mid-ride without moving the origin',
      () {
        final c = makeContainer();
        final nearest = c.read(nearestStationProvider.notifier);
        // The rider picked Kalyan, then the train reaches Thane. The chip must
        // follow the train; the origin must not.
        c.read(journeyDraftProvider.notifier).setOrigin('kalyan');
        nearest.applyFix(19.1864830, 72.9757664, 12);

        expect(c.read(nearestStationProvider).stationName, 'Thane');
        expect(c.read(journeyDraftProvider).originId, 'kalyan');
      },
    );

    test('a GPS-filled origin also stays put once the ride has started', () {
      // The ordinary ride: nobody touched the picker, the fix filled Kalyan,
      // Start confirmed it. The streamed fixes must not walk it to Thane.
      final c = makeContainer();
      final nearest = c.read(nearestStationProvider.notifier);
      nearest.applyFix(19.2358216, 73.1308101, 13);
      expect(c.read(journeyDraftProvider).originId, 'kalyan');

      c.read(journeyDraftProvider.notifier).confirmOrigin();
      nearest.applyFix(19.1864830, 72.9757664, 12);

      expect(c.read(nearestStationProvider).stationName, 'Thane');
      expect(c.read(journeyDraftProvider).originId, 'kalyan');
    });

    test(
      'a fix before Start moves the origin, because the rider is walking in',
      () {
        // The other half of the same rule, and why the fix is allowed to move a
        // default at all: the app opens on the walk to the platform.
        final c = makeContainer();
        final nearest = c.read(nearestStationProvider.notifier);
        nearest.applyFix(19.2358216, 73.1308101, 13);
        nearest.applyFix(19.1864830, 72.9757664, 12);

        expect(c.read(journeyDraftProvider).originId, 'thane');
      },
    );
  });
}
