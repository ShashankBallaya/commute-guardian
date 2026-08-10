import 'dart:io';

import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/models/journey.dart';
import 'package:commute_guardian/screens/arrival_screen.dart';
import 'package:commute_guardian/screens/destination_picker_screen.dart';
import 'package:commute_guardian/screens/history_screen.dart';
import 'package:commute_guardian/screens/home_screen.dart';
import 'package:commute_guardian/services/journey_suggestion.dart';
import 'package:commute_guardian/screens/preparing_screen.dart';
import 'package:commute_guardian/screens/settings_screen.dart';
import 'package:commute_guardian/screens/travel_mode_screen.dart';
import 'package:commute_guardian/screens/wake_alert_screen.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// EVERY SCREEN, AT EVERY SIZE IT WILL MEET. Added 5 Aug 2026.
///
/// Screen 3's 12 px overflow with the keyboard up was found by eye on a device,
/// which is the expensive way and the way that only ever finds the screen you
/// happened to be looking at. This file measures instead: it pumps each screen
/// in each of its states, at the smallest phone we intend to run on and at the
/// 3T's real geometry, and fails on any RenderFlex overflow.
///
/// The sizes are deliberate, not a sweep. 320x568 is the floor (an iPhone SE
/// first generation, and the narrowest Android still in the wild). 360x640 is
/// the owner's 3T, the device every bench runs on. 412x915 is a modern
/// Android, where the failure mode is not overflow but a layout that stops
/// filling the screen, so it is here to keep the others honest.
///
/// The keyboard is a SIZE, not an event: a text field with the keyboard up
/// leaves a phone roughly 260 logical pixels tall, and that is where Screen 3
/// broke. It is applied through viewInsets so Scaffold shrinks the way it does
/// on a real device.
///
/// TEXT SCALE 1.3 IS INCLUDED AND IS NOT COSMETIC. A rider who needs bigger
/// text is disproportionately likely to be the rider who needs to be woken.
void main() {
  late String stationsJson;
  late StationRepository repo;
  late Journey journey;

  /// The longest name in the bundled data, so a row is stressed by real data
  /// rather than by an invented string. Currently Chhatrapati Shivaji Maharaj
  /// Terminus, which is also the busiest station on the line.
  late String longestName;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
    repo = StationRepository.parse(stationsJson);
    journey = repo.planner.plan(originId: 'thane', destinationId: 'kalyan');
    final names = repo.stationsById.values.map((s) => s.name).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    longestName = names.first;
  });

  /// One pumped frame, measured. Returns the overflow error if the frame laid
  /// out badly, or null when it is clean.
  ///
  /// Overflow is reported through FlutterError during layout, which the test
  /// binding collects, so takeException is the measurement. It has to be taken
  /// even on the passing path, or a later test inherits it.
  Future<String?> overflowIn(
    WidgetTester tester,
    Widget app, {
    required Size size,
    double keyboard = 0,
    double textScale = 1.0,
    Future<void> Function(WidgetTester)? after,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: app,
      ),
    );
    await tester.pumpAndSettle();
    if (after != null) await after(tester);

    final error = tester.takeException();
    if (error == null) return null;
    // The whole dump, not just the headline: the useful part is the render
    // object it names, which is what says WHICH row on the screen gave way.
    return error.toString();
  }

  /// The matrix every screen runs through. A screen names its own states; this
  /// names the geometry, so the two never drift apart per screen.
  void atEverySize(
    String description,
    Widget Function() build, {
    double keyboard = 0,
    Future<void> Function(WidgetTester)? after,
  }) {
    const sizes = <String, Size>{
      'floor 320x568': Size(320, 568),
      '3T 360x640': Size(360, 640),
      'tall 412x915': Size(412, 915),
    };
    for (final entry in sizes.entries) {
      for (final scale in <double>[1.0, 1.3]) {
        testWidgets('$description, ${entry.key}, text x$scale', (tester) async {
          final overflow = await overflowIn(
            tester,
            build(),
            size: entry.value,
            keyboard: keyboard,
            textScale: scale,
            after: after,
          );
          expect(overflow, isNull, reason: overflow ?? '');
        });
      }
    }
  }

  Widget wrap(Widget home, {List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: [
        stationRepositoryProvider.overrideWith(
          (ref) async => StationRepository.parse(stationsJson),
        ),
        fixAcquirerProvider.overrideWithValue(
          () async => throw StateError('no GPS'),
        ),
        appDatabaseProvider.overrideWith((ref) {
          final db = AppDatabase.inMemory();
          ref.onDispose(db.close);
          return db;
        }),
        ...overrides,
      ],
      child: MaterialApp(home: home),
    );
  }

  // ---------------------------------------------------------------- Screen 1

  atEverySize(
    'home, no history',
    () => wrap(HomeScreen(onStartTo: (_) {}, onNew: () {})),
  );

  // THE FULLEST Screen 1 CAN EVER BE: the suggestion card on top of three
  // saved routes. The suggestion was added on 8 Aug and it is a FOURTH card on
  // a screen whose cards already ran 95 px past the bottom once, at a raised
  // font size, before FillOrScroll. Measured rather than eyeballed, which is
  // the rule this suite exists to enforce.
  atEverySize(
    'home, suggestion over three saved routes',
    () => wrap(
      HomeScreen(onStartTo: (_) {}, onNew: () {}),
      overrides: [
        journeySuggestionProvider.overrideWith(
          (ref) async => const JourneySuggestion(
            destinationId: 'dadar',
            // The longest realistic name on the network, so the card is
            // measured at its worst rather than at its tidiest.
            destinationName: 'Chhatrapati Shivaji Maharaj Terminus',
            matches: 12,
            isHome: true,
          ),
        ),
        savedRoutesProvider.overrideWith(
          (ref) async => [
            for (final (id, label) in const [
              ('kalyan', 'Home'),
              ('thane', 'Work'),
              ('panvel', 'Mum and Dad'),
            ])
              SavedRoute(
                id: label.hashCode,
                label: label,
                destinationStationId: id,
                destinationName: id,
                createdAt: DateTime(2026, 8, 1),
              ),
          ],
        ),
      ],
    ),
  );

  // ---------------------------------------------------------------- Screen 2

  atEverySize(
    'picker, resting',
    () => wrap(DestinationPickerScreen(onPicked: (_) {})),
  );

  atEverySize(
    'picker, keyboard up',
    () => wrap(DestinationPickerScreen(onPicked: (_) {})),
    keyboard: 300,
  );

  atEverySize(
    'picker, keyboard up and typing',
    () => wrap(DestinationPickerScreen(onPicked: (_) {})),
    keyboard: 300,
    after: (tester) async {
      await tester.enterText(
        find.byKey(const Key('destination_search')),
        'Kal',
      );
      await tester.pumpAndSettle();
    },
  );

  atEverySize(
    'picker, keyboard up and no match',
    () => wrap(DestinationPickerScreen(onPicked: (_) {})),
    keyboard: 300,
    after: (tester) async {
      await tester.enterText(
        find.byKey(const Key('destination_search')),
        'Kalyn',
      );
      await tester.pumpAndSettle();
    },
  );

  // ---------------------------------------------------------------- Screen 3

  atEverySize(
    'preparing, waiting for a fix',
    () => MaterialApp(
      home: PreparingScreen(
        originName: null,
        destinationName: longestName,
        steps: const [
          PrepStep(
            label: 'Finding you',
            detail: 'This can take a few seconds indoors',
            status: PrepStatus.active,
          ),
          PrepStep(label: 'Watching for your stop', status: PrepStatus.pending),
          PrepStep(
            label: 'Direction',
            detail: 'Confirmed once the train moves',
            status: PrepStatus.pending,
          ),
        ],
        onCancel: () {},
      ),
    ),
  );

  atEverySize(
    'preparing, everything ready',
    () => MaterialApp(
      home: PreparingScreen(
        originName: longestName,
        destinationName: longestName,
        steps: const [
          PrepStep(label: 'Finding you', status: PrepStatus.done),
          PrepStep(label: 'Watching for your stop', status: PrepStatus.done),
          PrepStep(
            label: 'Direction',
            detail: 'Confirmed once the train moves',
            status: PrepStatus.done,
          ),
        ],
        onCancel: () {},
      ),
    ),
  );

  // ---------------------------------------------------------------- Screen 4

  for (final at in <String, int>{
    'at the origin': -1,
    'mid ride': 3,
    'one to go': 6,
  }.entries) {
    atEverySize(
      'travel mode, ${at.key}',
      () => MaterialApp(
        home: TravelModeScreen(
          journey: journey,
          reachedIndex: at.value,
          wakeChoice: WakeChoice.lastTwoStations,
          etaLine: 'Arriving around 19:24',
          onEndJourney: () {},
        ),
      ),
    );
  }

  // ------------------------------------------------------------ Wake alert

  atEverySize(
    'wake alert, climbing',
    () => MaterialApp(
      home: WakeAlertScreen(
        destinationName: longestName,
        lastPassedLine: 'Thakurli passed 19:49',
        climbing: true,
        onAcknowledge: () {},
      ),
    ),
  );

  atEverySize(
    'wake alert, at full volume',
    () => MaterialApp(
      home: WakeAlertScreen(
        destinationName: 'Kalyan',
        lastPassedLine: null,
        climbing: false,
        onAcknowledge: () {},
      ),
    ),
  );

  // ---------------------------------------------------------------- Screen 5

  atEverySize(
    'arrival, nothing counting yet',
    () => MaterialApp(
      home: ArrivalScreen(
        destinationName: longestName,
        summaryLine: '52 min • 18 stations • Dadar → Kalyan',
        onEndNow: () {},
      ),
    ),
  );

  atEverySize(
    'arrival, counting with the save card',
    () => MaterialApp(
      home: ArrivalScreen(
        destinationName: longestName,
        summaryLine: '52 min • 18 stations • Dadar → Kalyan',
        autoEndAt: DateTime(2026, 8, 5, 19, 53),
        clock: () => DateTime(2026, 8, 5, 19, 52, 21),
        onEndNow: () {},
        onExtend: () {},
        onSaveRoute: (_) {},
      ),
    ),
  );

  // ---------------------------------------------------------------- Screen 6

  atEverySize(
    'settings',
    () => MaterialApp(
      home: SettingsScreen(
        settings: const AppSettings(),
        availableLanguages: const {
          AppLanguage.english,
          AppLanguage.hindi,
          AppLanguage.marathi,
        },
        versionLine: 'Commute Guardian 1.0.0 (1)',
        readiness: const [
          ReadinessItem(label: 'Location, always', state: ReadinessState.ok),
          ReadinessItem(
            label: 'Battery use',
            state: ReadinessState.needsAttention,
            detail: 'Restricted. Android may stop the app mid journey.',
          ),
        ],
        onBack: () {},
        onPulseInterval: (_) {},
        onCrowdMode: (_) {},
        onVibrateWithPulse: (_) {},
        onAnnounceEveryStation: (_) {},
        onShareAnonymousUsage: (_) {},
        onLanguage: (_) {},
      ),
    ),
  );

  // ---------------------------------------------------------------- Screen 7

  atEverySize('history, empty', () => wrap(const HistoryScreen()));
}
