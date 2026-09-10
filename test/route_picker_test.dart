import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/route_option.dart';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/screens/preparing_flow.dart';
import 'package:commute_guardian/screens/preparing_screen.dart';
import 'package:commute_guardian/screens/route_picker_sheet.dart';
import 'package:commute_guardian/services/commit_announcer.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/theme/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// C7c, the picker.
///
/// ADR 0004, reported from Ghansoli: "I can go to CST through Vashi and through
/// Thane. My choice kaha se jau." The safety hole under it is what makes this
/// worth a suite of its own: `WakeEscalation` walks the interchanges the PLAN
/// requires, so a rider on a corridor the app did not plan never reaches the
/// station the cursor is waiting at, and there is no alarm at her stop at all.
void main() {
  late String stationsJson;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
  });

  /// The real planner over the real station data. Ghansoli to CSMT is the
  /// reported case and it genuinely has two corridors, so nothing here is
  /// staged.
  List<RouteOption> optionsFor(String originId, String destinationId) {
    final repo = StationRepository.parse(stationsJson);
    return repo.planner.planAlternatives(
      originId: originId,
      destinationId: destinationId,
    );
  }

  Widget wrapSheet(List<RouteOption> options, {List<String>? chosen}) =>
      MaterialApp(
        home: Scaffold(
          backgroundColor: Palette.ground,
          body: RoutePickerSheet(
            destinationName: 'CSMT',
            options: options,
            chosenChainIds: chosen,
          ),
        ),
      );

  group('the sheet says what a rider chooses on', () {
    testWidgets('BOTH OF HER CORRIDORS ARE NAMED, the way she named them', (
      tester,
    ) async {
      final options = optionsFor('ghansoli', 'csmt');
      expect(
        options.length,
        greaterThan(1),
        reason: 'the reported case, or this suite is testing nothing',
      );
      await tester.pumpWidget(wrapSheet(options));

      expect(find.text('Which way to CSMT?'), findsOneWidget);
      // Named by the interchange, which is how she said it and how m-Indicator
      // lists it. Never by kilometres.
      for (final option in options) {
        expect(
          find.text(option.viaLabel ?? 'Direct, no change'),
          findsOneWidget,
        );
      }
    });

    testWidgets('stops and changes, and NO kilometres anywhere', (
      tester,
    ) async {
      final options = optionsFor('ghansoli', 'csmt');
      await tester.pumpWidget(wrapSheet(options));

      final first = options.first;
      expect(
        find.textContaining('${first.stops} stops'),
        findsWidgets,
        reason: 'the number she counts down, matching the lock screen',
      );
      expect(find.textContaining('km'), findsNothing);
      expect(find.textContaining('minute'), findsNothing);
    });

    testWidgets('THE DEFAULT IS MARKED, because it is what she gets by doing '
        'nothing', (tester) async {
      final options = optionsFor('ghansoli', 'csmt');
      await tester.pumpWidget(wrapSheet(options));

      expect(find.text('Usual'), findsOneWidget);
      expect(find.text('Riding this'), findsNothing);
    });

    testWidgets('and the route she is ALREADY on outranks the default label', (
      tester,
    ) async {
      final options = optionsFor('ghansoli', 'csmt');
      final other = options.last;
      await tester.pumpWidget(wrapSheet(options, chosen: other.chainIds));

      expect(find.text('Riding this'), findsOneWidget);
      // The first card is the planner's own answer and still says so.
      expect(find.text('Usual'), findsOneWidget);
    });

    testWidgets('a tap answers with the CHAIN, which is the only exact key', (
      tester,
    ) async {
      final options = optionsFor('ghansoli', 'csmt');
      List<String>? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped = await showRoutePicker(
                  context: context,
                  destinationName: 'CSMT',
                  options: options,
                  chosenChainIds: null,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final second = options[1];
      await tester.tap(find.text(second.viaLabel ?? 'Direct, no change'));
      await tester.pumpAndSettle();

      expect(popped, second.chainIds);
      expect(
        popped!.length,
        second.journey.chain.length,
        reason:
            'ids, never a count: two corridors of equal length are the '
            'dangerous case a size check goes green on',
      );
    });

    testWidgets('AN HOURLY TRAIN IS LABELLED, never filtered', (tester) async {
      // ADR 0004 defect B, and the owner takes this MEMU by choice: Vasai Road
      // to Kalyan is 12 stops across the top against 38 down through Dadar.
      final options = optionsFor('vasai_road', 'kalyan');
      final hourly = options.where((o) => o.lowFrequency);
      expect(
        hourly,
        isNotEmpty,
        reason: 'the MEMU is offered at all, which is the whole of defect B',
      );
      await tester.pumpWidget(wrapSheet(options));

      expect(find.textContaining('about hourly'), findsWidgets);
      // And the normal ones say nothing: "every few minutes" on five cards out
      // of six teaches the eye to skip the word that matters.
      expect(find.textContaining('every few minutes'), findsNothing);
    });
  });

  group('the flow asks, and only when there is something to ask', () {
    /// Runs Screen 3 to its end for one journey, and reports what happened.
    ///
    /// The report is CLEAR, so the flow needs no GPS and no permission taps: it
    /// opens at preflight, settles itself, and the only thing that can stand
    /// between the tap and a running ride is the picker.
    Future<({bool? outcome, bool asked, ProviderContainer container})> runFlow(
      WidgetTester tester, {
      required String originId,
      required String destinationId,
      required String destinationName,
      String? tapVia,
    }) async {
      bool? outcome;
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stationRepositoryProvider.overrideWith(
              (ref) async => StationRepository.parse(stationsJson),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                home: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () async {
                      outcome = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => PreparingFlow(
                            announcer: _SilentAnnouncer(),
                            destinationName: destinationName,
                            report: const PreparingReport(
                              hasFix: true,
                              originName: 'here',
                              backgroundLocationGranted: true,
                              earphonesConnected: true,
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('go'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // THE REPOSITORY HAS TO BE RESOLVED BEFORE THE FLOW ASKS FOR IT. A
      // FutureProvider nobody is watching has not started, so
      // routeOptionsProvider would read a null repo, answer "no choice", and
      // this suite would pass by never asking anything.
      await container.read(stationRepositoryProvider.future);
      container.read(journeyDraftProvider.notifier)
        ..setOrigin(originId)
        ..setDestination(destinationId);

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      final asked = find.byType(RoutePickerSheet).evaluate().isNotEmpty;
      if (asked) {
        if (tapVia == null) {
          // The scrim: a rider who does not want to choose.
          await tester.tapAt(const Offset(20, 20));
        } else {
          await tester.tap(find.text(tapVia));
        }
        await tester.pumpAndSettle();
      }
      return (outcome: outcome, asked: asked, container: container);
    }

    testWidgets('SHE IS ASKED on the corridor she reported', (tester) async {
      final run = await runFlow(
        tester,
        originId: 'ghansoli',
        destinationId: 'csmt',
        destinationName: 'CSMT',
      );
      expect(run.asked, isTrue);
    });

    testWidgets(
      'A PICK IS WRITTEN TO THE DRAFT, which is what survives a kill',
      (tester) async {
        final repo = StationRepository.parse(stationsJson);
        final options = repo.planner.planAlternatives(
          originId: 'ghansoli',
          destinationId: 'csmt',
        );
        final other = options[1];

        final run = await runFlow(
          tester,
          originId: 'ghansoli',
          destinationId: 'csmt',
          destinationName: 'CSMT',
          tapVia: other.viaLabel ?? 'Direct, no change',
        );

        expect(
          run.container.read(journeyDraftProvider).routeChainIds,
          other.chainIds,
          reason:
              'without this a kill re-derives the route and hands her the other '
              'corridor, then wakes her against a chain she is not on',
        );
        // And the plan the rest of the app reads followed her, not the planner.
        expect(
          run.container
              .read(plannedJourneyProvider)
              .journey!
              .chain
              .map((s) => s.id),
          other.chainIds,
        );
        expect(run.outcome, isTrue, reason: 'and the ride still starts');
      },
    );

    testWidgets('A DISMISSAL IS A DECISION, NOT A DEAD END', (tester) async {
      // The half of ADR 0004's "do not block" worth keeping. A sheet a pocketed
      // phone could leave sitting there, with no ride running and nothing said,
      // would be worse than the bug this fixes.
      final run = await runFlow(
        tester,
        originId: 'ghansoli',
        destinationId: 'csmt',
        destinationName: 'CSMT',
      );

      expect(run.asked, isTrue);
      expect(
        run.outcome,
        isTrue,
        reason: 'the ride begins anyway, on the route she already had',
      );
      expect(
        run.container.read(journeyDraftProvider).routeChainIds,
        isNull,
        reason:
            'untouched, so planAlong falls through to plan and she rides '
            'exactly what a rider who never looks rides',
      );
    });

    testWidgets(
      'AND NOT ASKED ON A JOURNEY WITH ONE WAY, which is most of them',
      (tester) async {
        final run = await runFlow(
          tester,
          originId: 'kalyan',
          destinationId: 'dombivli',
          destinationName: 'Dombivli',
        );
        expect(
          run.container.read(routeOptionsProvider).length,
          1,
          reason: 'one corridor, so there is nothing to ask',
        );
        expect(run.asked, isFalse);
        expect(
          run.outcome,
          isTrue,
          reason: 'the ride starts with no extra tap asked of her',
        );
      },
    );
  });

  group('the two ways the pick used to be lost, both found by review', () {
    setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

    test('A STREAMED FIX DURING THE WINDOW CANNOT REVERT HER CORRIDOR', () {
      // The window runs for three more seconds after the pick. `applyFix` is
      // still live, and it calls `defaultOriginTo`, which builds a FRESH draft
      // and drops `routeChainIds` by omitting it. The ride would have begun on
      // the ordinary corridor while the window still printed the chosen one.
      //
      // `confirmOrigin` at the moment of the pick is what closes it: choosing a
      // corridor is choosing where you are standing.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final draft = container.read(journeyDraftProvider.notifier)
        ..setDestination('csmt');
      // FILLED BY GPS, NOT PICKED, which is the real path and the only one
      // where this can go wrong: `setOrigin` already marks the origin the
      // rider's own, so a test built on it cannot reproduce the fault.
      draft
        ..defaultOriginTo('ghansoli')
        ..setChosenRoute(['ghansoli', 'thane', 'csmt'])
        ..confirmOrigin();

      final moved = draft.defaultOriginTo('kalyan');

      expect(moved, isFalse, reason: 'her origin is hers once she has chosen');
      expect(container.read(journeyDraftProvider).routeChainIds, [
        'ghansoli',
        'thane',
        'csmt',
      ]);
    });

    test('and the guard can still fail: without the confirm it IS lost', () {
      // The bug as it stood, so this pair can never both pass by accident.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final draft = container.read(journeyDraftProvider.notifier)
        ..setDestination('csmt');
      draft
        ..defaultOriginTo('ghansoli')
        ..setChosenRoute(['ghansoli', 'thane', 'csmt']);

      draft.defaultOriginTo('kalyan');

      expect(
        container.read(journeyDraftProvider).routeChainIds,
        isNull,
        reason: 'this is what the confirm above is protecting against',
      );
    });
  });

  testWidgets('SHE IS STILL ASKED WHEN THE STATION DATA ARRIVES LATE', (
    tester,
  ) async {
    // `routeOptionsProvider` answers `const []` while the repository future is
    // unresolved, and an empty list reads as "no choice to offer". A cold
    // launch where the rider taps a saved route before the asset has parsed
    // would therefore skip the picker in silence.
    //
    // The rest of this suite could not see it: its harness awaits the
    // repository by hand before tapping.
    bool? outcome;
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith((ref) async {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            return StationRepository.parse(stationsJson);
          }),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              home: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    outcome = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => PreparingFlow(
                          announcer: _SilentAnnouncer(),
                          destinationName: 'CSMT',
                          report: const PreparingReport(
                            hasFix: true,
                            originName: 'Ghansoli',
                            backgroundLocationGranted: true,
                            earphonesConnected: true,
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    // NOT awaited by hand, which is the whole point of this test.
    container.read(journeyDraftProvider.notifier)
      ..setOrigin('ghansoli')
      ..setDestination('csmt');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(
      find.byType(RoutePickerSheet),
      findsOneWidget,
      reason: 'the flow must wait for the stations before deciding to ask',
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(outcome, isTrue);
  });

  group('the wiring itself, because a helper nobody calls is not a feature', () {
    String source(String path) => File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .split('\n')
        .map((line) {
          final comment = line.indexOf('//');
          return comment == -1 ? line : line.substring(0, comment);
        })
        .join('\n');

    test('THERE IS EXACTLY ONE DOOR INTO THE COMMIT WINDOW', () {
      // The lesson this project keeps re-learning: a gate that covers the path
      // you were looking at is not a gate. Two places used to open the window
      // by hand, the clear ride and the preflight Start, and adding the ask to
      // one of them would have left the other silently unguarded.
      final flow = source('lib/screens/preparing_flow.dart');

      expect(
        RegExp(r'_stage = _Stage\.committing').allMatches(flow).length,
        1,
        reason: 'a second setter is a second path that never asks',
      );
      expect(
        RegExp(r'_runCommitWindow\(\)').allMatches(flow).length,
        2,
        reason: 'the declaration and exactly one call, both inside the door',
      );
      expect(
        RegExp(r'_enterCommitWindow\(\)').allMatches(flow).length,
        3,
        reason: 'the declaration plus its two callers',
      );
    });

    test('and that guard can still fail, proved against the old shape', () {
      const before = '''
      setState(() => _stage = _Stage.committing);
      unawaited(_runCommitWindow());
        onStart: () {
          setState(() => _stage = _Stage.committing);
          unawaited(_runCommitWindow());
        },
''';
      expect(
        RegExp(r'_stage = _Stage\.committing').allMatches(before).length,
        2,
        reason: 'the shape this replaced had two doors, and the guard sees it',
      );
    });

    test('THE ASK IS WIRED, not merely written', () {
      final flow = source('lib/screens/preparing_flow.dart');
      expect(flow, contains('showRoutePicker('));
      expect(flow, contains('setChosenRoute('));
      // The two review fixes, wired rather than merely written. Without the
      // first, a streamed fix during the window reverts her corridor; without
      // the second, a cold launch skips the question in silence.
      expect(
        flow,
        contains('confirmOrigin()'),
        reason: 'the pick must put the origin beyond the reach of a fix',
      );
      expect(
        flow.indexOf('stationRepositoryProvider.future'),
        lessThan(flow.indexOf('routeOptionsProvider')),
        reason: 'reading the options before the stations answers const []',
      );
      expect(
        flow.indexOf('_chooseRoute()'),
        lessThan(flow.indexOf('_stage = _Stage.committing')),
        reason: 'asking after the window has opened asks too late',
      );
    });
  });

  group('the commit window names the corridor', () {
    Widget wrapWindow({String? via}) => MaterialApp(
      home: StartingScreen(
        originName: 'Ghansoli',
        destinationName: 'CSMT',
        viaLabel: via,
        remaining: const AlwaysStoppedAnimation(1),
        onCancel: () {},
      ),
    );

    testWidgets('it prints the route she is about to ride', (tester) async {
      await tester.pumpWidget(wrapWindow(via: 'via Thane'));
      expect(find.byKey(const Key('starting_via')), findsOneWidget);
      expect(find.text('via Thane'), findsOneWidget);
    });

    testWidgets('AND SAYS NOTHING ON A RIDE WITH NO CHANGE IN IT', (
      tester,
    ) async {
      // A direct ride has no "which way" to answer, and three seconds is not
      // the place for a line that answers nothing.
      await tester.pumpWidget(wrapWindow());
      expect(find.byKey(const Key('starting_via')), findsNothing);
    });

    testWidgets('the line is text, never a control', (tester) async {
      await tester.pumpWidget(wrapWindow(via: 'via Thane'));
      // The choice belongs to the step before this one, where there is time to
      // read it. A tappable row here would put a second decision inside three
      // seconds.
      expect(
        find.ancestor(
          of: find.byKey(const Key('starting_via')),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });
  });
}

/// The commit window without a TTS engine. The real one would reach for
/// flutter_tts and the window awaits it before it commits.
class _SilentAnnouncer extends CommitAnnouncer {
  _SilentAnnouncer();

  @override
  Future<bool> speak(String line, {required AppLanguage language}) async =>
      true;
}
