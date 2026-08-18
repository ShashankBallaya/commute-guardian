import 'package:commute_guardian/screens/speed_screen.dart';
import 'package:commute_guardian/state/ride_speed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The speed screen, and the three states it has to draw.
///
/// The one it exists to get right is the middle one. Both platforms report a
/// speed of -1 to mean "no reading", and every desk log this project has is
/// full of `speed -1.0m/s`. A screen that renders that shows a train doing
/// minus one; a screen that clamps it to zero tells a rider on a moving train
/// that they are stopped.
void main() {
  Future<void> pump(WidgetTester tester, {RideSpeed? speed}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (speed != null)
            rideSpeedProvider.overrideWith(() => _FakeSpeed(speed)),
        ],
        child: const MaterialApp(home: SpeedScreen()),
      ),
    );
    await tester.pump();
  }

  // READ PER TEST, NOT ONCE. A single `now` captured here ages while the suite
  // runs, and the staleness tests below compare against a 20 second window: the
  // margin quietly shrinks by however long the earlier tests took, which is a
  // test that fails on a slow machine and passes on a fast one.
  DateTime now() => DateTime.now();

  group('the three states', () {
    testWidgets('a reading is a whole number in km/h', (tester) async {
      await pump(tester, speed: RideSpeed(kmh: 107.6, at: now()));

      expect(find.byKey(const Key('speed_value')), findsOneWidget);
      expect(find.text('108'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(
        find.byKey(const Key('speed_no_reading')),
        findsNothing,
        reason: 'a real reading must never draw the dash',
      );
    });

    testWidgets('NO READING DRAWS A DASH, NEVER A ZERO', (tester) async {
      await pump(tester, speed: const RideSpeed());

      expect(find.byKey(const Key('speed_no_reading')), findsOneWidget);
      expect(find.text('Waiting for a GPS reading'), findsOneWidget);
      expect(
        find.text('0'),
        findsNothing,
        reason: 'zero would tell a moving rider they are stopped',
      );
    });

    testWidgets('A REAL ZERO SAYS STOPPED, and is not the same thing', (
      tester,
    ) async {
      // The case the null sentinel must not swallow: a train standing at a
      // platform reports 0.0, which is true.
      await pump(tester, speed: RideSpeed(kmh: 0, at: now()));

      expect(find.text('0'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('km/h'), findsNothing);
      expect(find.byKey(const Key('speed_no_reading')), findsNothing);
    });
  });

  group('STALENESS, which is the only lie this screen could tell', () {
    testWidgets('a reading older than the window stops being shown', (
      tester,
    ) async {
      // At line speed a 20 second old number is 600 m out of date. A screen
      // that says 80 while the train stands at a signal is worse than one that
      // admits it does not know.
      await pump(
        tester,
        speed: RideSpeed(
          kmh: 80,
          at: now().subtract(RideSpeed.staleAfter + const Duration(seconds: 1)),
        ),
      );

      expect(find.byKey(const Key('speed_no_reading')), findsOneWidget);
      expect(find.text('80'), findsNothing);
    });

    testWidgets('and one inside the window still is', (tester) async {
      await pump(
        tester,
        speed: RideSpeed(
          kmh: 80,
          at: now().subtract(const Duration(seconds: 5)),
        ),
      );

      expect(find.text('80'), findsOneWidget);
    });
  });

  group('the fastest line', () {
    testWidgets('is absent until there has been a reading', (tester) async {
      await pump(tester, speed: const RideSpeed());
      expect(find.byKey(const Key('speed_fastest')), findsNothing);
    });

    testWidgets('SURVIVES A GAP IN READINGS, because the ride did', (
      tester,
    ) async {
      // A stretch with no fixes must not erase what the ride has already done.
      // The maximum belongs to the journey, not to the last fix.
      await pump(tester, speed: RideSpeed(maxKmh: 107.6, at: now()));

      expect(find.byKey(const Key('speed_no_reading')), findsOneWidget);
      expect(find.text('Fastest this ride 108 km/h'), findsOneWidget);
    });
  });

  group('the notifier', () {
    test('THE MAXIMUM ONLY RISES, and never from a null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(rideSpeedProvider.notifier);

      notifier.applyFix(40, now());
      notifier.applyFix(107.6, now());
      notifier.applyFix(60, now());
      expect(container.read(rideSpeedProvider).maxKmh, 107.6);

      notifier.applyFix(null, now());
      expect(
        container.read(rideSpeedProvider).maxKmh,
        107.6,
        reason: 'losing the signal must not erase the ride',
      );
      expect(container.read(rideSpeedProvider).kmh, isNull);
    });

    test('JITTER ON A STATIONARY PHONE IS NOT A RIDE RECORD', () {
      // The first build of this screen sat on a desk that had not moved all
      // evening and reported "Fastest this ride 2 km/h". Android returns a real
      // speed rather than a -1 sentinel, and a stationary GPS wanders.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(rideSpeedProvider.notifier);

      notifier.applyFix(2, now());
      expect(container.read(rideSpeedProvider).maxKmh, isNull);
      // And the LIVE number still tells the truth, whatever it is.
      expect(container.read(rideSpeedProvider).kmh, 2);

      notifier.applyFix(64, now());
      expect(container.read(rideSpeedProvider).maxKmh, 64);
    });

    test('A NEW RIDE STARTS AT NOTHING', () {
      // Carrying yesterday's 107 into today is the same class of bug as a new
      // ride inheriting the last one's progress index.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(rideSpeedProvider.notifier);

      notifier.applyFix(107.6, now());
      notifier.reset();

      expect(container.read(rideSpeedProvider).maxKmh, isNull);
      expect(container.read(rideSpeedProvider).kmh, isNull);
    });
  });

  testWidgets('the back control clears the touch floor', (tester) async {
    await pump(tester, speed: const RideSpeed());
    final height = tester.getSize(find.byKey(const Key('speed_back'))).height;
    expect(
      height,
      greaterThanOrEqualTo(48.0),
      reason: 'a new screen starts at the floor rather than inheriting a miss',
    );
  });
}

class _FakeSpeed extends RideSpeedNotifier {
  _FakeSpeed(this._value);

  final RideSpeed _value;

  @override
  RideSpeed build() => _value;
}
