import 'dart:async';
import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/screens/preparing_flow.dart';
import 'package:commute_guardian/screens/preparing_screen.dart';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/services/audio_output_gateway.dart';
import 'package:commute_guardian/services/commit_announcer.dart';
import 'package:commute_guardian/widgets/pressable.dart';
import 'package:commute_guardian/state/journey_providers.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ride_service_client.dart';

/// Screen 3, wired.
///
/// The thing most worth pinning is the NEGATIVE: on an ordinary ride this flow
/// must never appear. The fix is normally already held, so a gate that pushed
/// itself unconditionally would flash a progress screen on every journey.
void main() {
  late String stationsJson;

  setUpAll(() {
    stationsJson = File(StationRepository.assetPath).readAsStringSync();
  });

  fl.Location fixAt(double lat, double lng) => fl.Location(
    latitude: lat,
    longitude: lng,
    accuracy: 10,
    altitude: 0,
    heading: 0,
    speed: 0,
    speedAccuracy: 0,
    millisecondsSinceEpoch: 0,
    timestamp: DateTime(2026, 7, 29),
    isMock: false,
  );

  // Shahad.
  const shahadLat = 19.2403;
  const shahadLng = 73.1310;

  /// Hears the commit window without a TTS engine.
  ///
  /// NOTE WHAT IT CANNOT DO: there is no stop(). [CommitAnnouncer] has no way
  /// to cancel an utterance, on purpose, because iOS sends no didCancel for
  /// tts.stop() and a ride that waits for that completion waits forever.
  final spokenLines = <String>[];

  Future<bool?> pumpFlow(
    WidgetTester tester, {
    required PreparingReport report,
    FixAcquirer? acquirer,
    bool cancelWindow = false,
    bool tapPreflightStart = false,
  }) async {
    bool? outcome;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          if (acquirer != null) fixAcquirerProvider.overrideWithValue(acquirer),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                outcome = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => PreparingFlow(
                      destinationName: 'Kalyan',
                      report: report,
                      announcer: _RecordingAnnouncer(spokenLines),
                    ),
                  ),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));

    if (cancelWindow) {
      // NOT pumpAndSettle. Settling runs the window's own animation to its
      // end, which COMMITS the ride, so a settle here would test the opposite
      // of what this asks. Stop partway through instead, the way a rider does.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('starting_cancel')),
        findsOneWidget,
        reason: 'the window must still be open to cancel from',
      );
      await tester.tap(find.byKey(const Key('starting_cancel')));
      await tester.pumpAndSettle();
      return outcome;
    }

    await tester.pumpAndSettle();

    if (tapPreflightStart) {
      await tester.tap(find.byKey(const Key('preflight_start')));
      await tester.pumpAndSettle();
    }

    // THE FLOW NOW ENDS IN A THREE SECOND WINDOW, and pumpAndSettle has
    // already run it to the end, which is what a rider who does nothing gets.
    return outcome;
  }

  // RENAMED 26 Aug 2026. `clear` no longer decides whether the rider sees this
  // flow at all: since the commit window, the flow is pushed on EVERY ride and
  // `clear` only decides which state it opens in. The getter is unchanged.
  test('a clear report means there is nothing to warn about', () {
    const clear = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: true,
    );
    expect(clear.clear, isTrue);
  });

  test('any one failed probe is enough to stop and say so', () {
    const noFix = PreparingReport(
      hasFix: false,
      originName: null,
      backgroundLocationGranted: true,
      earphonesConnected: true,
    );
    const noPermission = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: false,
      earphonesConnected: true,
    );
    const noEarphones = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: false,
    );
    expect(noFix.clear, isFalse);
    expect(noPermission.clear, isFalse);
    expect(noEarphones.clear, isFalse);
  });

  // THE VOLUME CHECK, built 11 Aug 2026 after a real silent alarm. The ladder
  // went live, seized the session exclusively, climbed all three rungs, and the
  // owner heard nothing. Nothing in the app had ever read the system volume,
  // although this file's own doc listed it as one of the two audio checks and
  // the debug screen has carried a "Volume is low" chip wired to nothing.
  group('the volume warning', () {
    PreparingReport withVolume(double? volume) => PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: true,
      alarmVolume: volume,
    );

    test('a low volume stops the ride starting silently', () {
      expect(withVolume(0.0).volumeLow, isTrue);
      expect(withVolume(0.1).volumeLow, isTrue);
      expect(withVolume(0.0).clear, isFalse);
    });

    test('an adequate volume says nothing at all', () {
      expect(withVolume(0.5).volumeLow, isFalse);
      expect(withVolume(1.0).volumeLow, isFalse);
      expect(withVolume(0.5).clear, isTrue);
    });

    test('the boundary is a floor, not a ceiling', () {
      // Exactly at the threshold is fine. Only BELOW it warns, so the constant
      // reads the way its name does.
      expect(withVolume(AudioOutputGateway.lowVolume).volumeLow, isFalse);
      expect(withVolume(AudioOutputGateway.lowVolume - 0.01).volumeLow, isTrue);
    });

    test('AN UNREADABLE VOLUME IS NOT A WARNING', () {
      // Fails open, like every other probe on this screen. A warning we cannot
      // stand behind, shown before every ride, teaches the rider to tap past
      // the screen on the ride where it mattered.
      expect(withVolume(null).volumeLow, isFalse);
      expect(withVolume(null).clear, isTrue);
    });
  });

  testWidgets('with no fix it waits, then leaves on its own once found', (
    tester,
  ) async {
    // Everything else already passes, so a landed fix means there is nothing
    // left to say and the flow must settle itself rather than making the rider
    // dismiss a screen that has no news.
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: false,
        originName: null,
        backgroundLocationGranted: true,
        earphonesConnected: true,
      ),
      acquirer: () async => fixAt(shahadLat, shahadLng),
    );
    expect(outcome, isTrue);
  });

  testWidgets('THE ROW THAT COULD NEVER BE READ IS GONE, 27 Aug 2026', (
    tester,
  ) async {
    // The AirPods gap, 12 Aug 2026. `alarmVolume()` reads the current output
    // ROUTE, so a fine number with earphones connected describes the
    // EARPHONES and says nothing about the speaker the alarm falls back to
    // when they run out of battery an hour into a commute. On the owner's
    // own iPhone that speaker is at zero.
    //
    // The app used to answer that with a preflight row reading "Checked your
    // earphone volume". It drew only when `_earphonesConnected &&
    // !_volumeLow`, which is precisely the report that leaves this screen:
    // before 26 Aug the gate never pushed the flow at all, and after it the
    // flow settles straight into the commit window. No rider ever read it.
    //
    // THE GAP IS REAL AND STILL OPEN. It needs a surface a rider meets
    // before they are mid-Start, which is Screen 1's readiness card, not
    // three seconds of a window whose whole job is catching a mis-tap. This
    // test pins the deletion so the dead row does not come back in place of
    // that work.
    // Driven with cancelWindow, which stops PART WAY through the window
    // instead of settling it. A settle would run the window to its end and
    // commit the ride, and this needs the flow held open to look at.
    await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: true,
        originName: 'Shahad',
        backgroundLocationGranted: true,
        earphonesConnected: true,
      ),
      cancelWindow: true,
    );

    expect(find.text('Checked your earphone volume'), findsNothing);
    expect(
      find.textContaining("phone's own volume isn't visible"),
      findsNothing,
    );
  });

  testWidgets(
    'a low volume DRAWS the warning that had never been wired to anything',
    (tester) async {
      // The chip existed on the debug screen from the day Screen 3 was drawn
      // and nothing could ever produce it, because nothing read the volume.
      // This is the test that says the wire is real, not the constant.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stationRepositoryProvider.overrideWith(
              (ref) async => StationRepository.parse(stationsJson),
            ),
            fixAcquirerProvider.overrideWithValue(
              () async => fixAt(shahadLat, shahadLng),
            ),
          ],
          child: const MaterialApp(
            home: PreparingFlow(
              destinationName: 'Kalyan',
              report: PreparingReport(
                hasFix: true,
                originName: 'Shahad',
                backgroundLocationGranted: true,
                // Earphones IN, so the only thing wrong is the volume and the
                // screen cannot be passing for the other reason.
                earphonesConnected: true,
                alarmVolume: 0.05,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // NAMES THE DEVICE since 12 Aug 2026. `alarmVolume()` reads the current
      // output ROUTE, so with earphones connected this reading describes the
      // EARPHONES and says nothing about the speaker the alarm falls back to
      // when they die mid-commute. The fixture has earphones IN, so the copy
      // must say so.
      expect(find.text('Your earphone volume is low'), findsOneWidget);
      expect(find.text('Volume is low'), findsNothing);
      expect(find.text("Your earphones aren't connected"), findsNothing);
    },
  );

  // "I'VE FIXED IT, CHECK AGAIN" HAD NO ANSWER, reported on device 11 Aug 2026:
  // "there's no refresh/delay or something to know if it works as the screen
  // remains stale which is Bad UX". The probes return in milliseconds, so a
  // correct result landed before the finger left the glass, and an unchanged
  // one left a byte-identical screen.
  group('the recheck control says what it did', () {
    Future<void> pumpPreflight(
      WidgetTester tester, {
      required FakeRideServiceClient client,
      AudioOutputGateway audio = const _EarphonesIn(),
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stationRepositoryProvider.overrideWith(
              (ref) async => StationRepository.parse(stationsJson),
            ),
            fixAcquirerProvider.overrideWithValue(
              () async => fixAt(shahadLat, shahadLng),
            ),
            rideServiceClientProvider.overrideWithValue(client),
          ],
          child: MaterialApp(
            home: PreparingFlow(
              destinationName: 'Kalyan',
              audio: audio,
              report: const PreparingReport(
                hasFix: true,
                originName: 'Shahad',
                backgroundLocationGranted: true,
                earphonesConnected: true,
                alarmVolume: 0.05,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('an unchanged answer SAYS SO instead of looking untouched', (
      tester,
    ) async {
      // Still low. The old build returned silently to an identical screen.
      final client = FakeRideServiceClient()..alarmVolumeValue = 0.05;
      await pumpPreflight(tester, client: client);
      expect(find.text("I've fixed it, check again"), findsOneWidget);

      await tester.tap(find.byKey(const Key('preflight_recheck')));
      await tester.pump();
      expect(
        find.text('Checking…'),
        findsOneWidget,
        reason: 'the tap must be visible before the answer is',
      );

      // Held past the minimum even though the probe already returned.
      await tester.pump(PreflightScreen.recheckMinimum);
      await tester.pumpAndSettle();
      expect(find.text('No change yet'), findsOneWidget);
      expect(
        find.text('Your earphone volume is low'),
        findsOneWidget,
        reason: 'the warning is still true, so it stays',
      );

      // And it goes back, so the control is usable again.
      await tester.pump(PreflightScreen.recheckSettle);
      await tester.pumpAndSettle();
      expect(find.text("I've fixed it, check again"), findsOneWidget);
    });

    testWidgets('a fixed volume clears the row and needs no words', (
      tester,
    ) async {
      final client = FakeRideServiceClient()..alarmVolumeValue = 0.05;
      await pumpPreflight(tester, client: client);
      expect(find.text('Your earphone volume is low'), findsOneWidget);

      // The rider turns it up between the screen appearing and the press.
      client.alarmVolumeValue = 0.8;
      await tester.tap(find.byKey(const Key('preflight_recheck')));
      await tester.pump();
      await tester.pump(PreflightScreen.recheckMinimum);
      await tester.pumpAndSettle();

      expect(find.text('Your earphone volume is low'), findsNothing);
      expect(
        find.text('No change yet'),
        findsNothing,
        reason: 'a row disappearing is its own feedback; do not narrate it',
      );
    });

    testWidgets('a second press during the check is refused', (tester) async {
      // A control that can be pressed during its own answer invites the rider
      // to press again and see nothing, which is the original complaint.
      final client = FakeRideServiceClient()..alarmVolumeValue = 0.05;
      await pumpPreflight(tester, client: client);

      await tester.tap(find.byKey(const Key('preflight_recheck')));
      await tester.pump();
      expect(find.text('Checking…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('preflight_recheck')),
          matching: find.byType(Pressable),
        ),
        findsNothing,
        reason: 'a disabled control must not scale down as though it acted',
      );

      await tester.pump(PreflightScreen.recheckMinimum);
      await tester.pumpAndSettle();
      await tester.pump(PreflightScreen.recheckSettle);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the promise never invents an origin it does not have', (
    tester,
  ) async {
    // State A exists BECAUSE the origin is unknown, so "Shahad to Kalyan" is a
    // claim the screen cannot make yet.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          // Never resolves: holds the flow in state A so it can be read.
          fixAcquirerProvider.overrideWithValue(
            () => Completer<fl.Location>().future,
          ),
        ],
        child: const MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: false,
              originName: null,
              backgroundLocationGranted: true,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('To Kalyan', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Getting ready'), findsOneWidget);
  });

  testWidgets('a failed fix lands on state B, not a spinner forever', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          fixAcquirerProvider.overrideWithValue(
            () async => throw StateError('no GPS'),
          ),
        ],
        child: const MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: false,
              originName: null,
              backgroundLocationGranted: true,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("We can't find you yet"), findsOneWidget);
  });

  testWidgets('refused background location stops the ride until answered', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: PreparingFlow(
            destinationName: 'Kalyan',
            report: PreparingReport(
              hasFix: true,
              originName: 'Shahad',
              backgroundLocationGranted: false,
              earphonesConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("We can't wake you with the screen off"), findsOneWidget);
  });

  testWidgets('start anyway carries straight through to the ride', (
    tester,
  ) async {
    // Earphones are fine here, so there is nothing after the permission screen
    // and the flow must not park the rider on an empty checklist.
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: true,
        originName: 'Shahad',
        backgroundLocationGranted: false,
        earphonesConnected: true,
      ),
    );
    expect(outcome, isNull, reason: 'not started yet, the screen is showing');

    await tester.tap(find.byKey(const Key('background_location_start_anyway')));
    await tester.pumpAndSettle();
  });

  testWidgets('missing earphones warn once and never block', (tester) async {
    final outcome = await pumpFlow(
      tester,
      report: const PreparingReport(
        hasFix: true,
        originName: 'Shahad',
        backgroundLocationGranted: true,
        earphonesConnected: false,
      ),
    );
    expect(outcome, isNull);

    expect(find.text('One thing before you doze off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preflight_start')));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling state A abandons rather than starting a ride', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stationRepositoryProvider.overrideWith(
            (ref) async => StationRepository.parse(stationsJson),
          ),
          fixAcquirerProvider.overrideWithValue(
            () => Completer<fl.Location>().future,
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const PreparingFlow(
                    destinationName: 'Kalyan',
                    report: PreparingReport(
                      hasFix: false,
                      originName: null,
                      backgroundLocationGranted: true,
                      earphonesConnected: true,
                    ),
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('preparing_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('go'), findsOneWidget, reason: 'back where they started');
  });

  /// THE COMMIT WINDOW, added 26 Aug 2026.
  ///
  /// The one screen on this flow that is not a problem. It exists so a mis-tap
  /// never becomes a ride: Kalyan and Kalwa are one fat-finger apart in the
  /// picker, and by the time Screen 4 draws the route the ride is real, which
  /// costs a junk History row and a false ride_started in the only telemetry
  /// this beta has.
  group('THE COMMIT WINDOW', () {
    const clear = PreparingReport(
      hasFix: true,
      originName: 'Shahad',
      backgroundLocationGranted: true,
      earphonesConnected: true,
    );

    testWidgets('A CLEAR RIDE NOW SEES A SCREEN, and used to see none', (
      tester,
    ) async {
      final outcome = await pumpFlow(tester, report: clear);

      // It still ends in a ride. It just stops at the window on the way.
      expect(outcome, isTrue);
    });

    testWidgets('it speaks the route while cancel is still live', (
      tester,
    ) async {
      spokenLines.clear();
      await pumpFlow(tester, report: clear);

      expect(spokenLines, hasLength(1));
      // BOTH station names, because both halves of the contract are what the
      // rider is checking, and the 9 Aug stale-origin bug was about the half
      // that is easy to leave out.
      expect(spokenLines.single, contains('Shahad'));
      expect(spokenLines.single, contains('Kalyan'));
      // "Starting", never "is on". The ride has not happened yet and may not.
      expect(spokenLines.single, contains('Starting'));
      expect(spokenLines.single, isNot(contains('is on')));
    });

    testWidgets('CANCEL MEANS NO RIDE EVER STARTED', (tester) async {
      final outcome = await pumpFlow(tester, report: clear, cancelWindow: true);

      // FALSE, not null: the rider answered, and the answer was no. Nothing
      // downstream has to be undone because nothing was ever done.
      expect(outcome, isFalse);
    });

    testWidgets('cancelling still let the sentence finish', (tester) async {
      spokenLines.clear();
      await pumpFlow(tester, report: clear, cancelWindow: true);

      // The line was spoken and never stopped. CommitAnnouncer has no stop()
      // at all: iOS sends no didCancel for tts.stop(), so a stopped utterance
      // is a completion that never arrives.
      expect(spokenLines, hasLength(1));
    });

    testWidgets('A POCKETED PHONE STILL GETS ITS RIDE', (tester) async {
      // THE BUG THIS WINDOW ALMOST SHIPPED WITH. Flutter mutes tickers when
      // the app stops producing frames, which is what a pocketed phone does.
      // While the commit was gated on the ring's AnimationController, a rider
      // who tapped Start and put the phone away got no ride at all: the ring
      // stalled and nothing ever committed. The clock is a Timer now, and the
      // ring is only the picture of it.
      //
      // Pumping ZERO frames after the window opens is the desk version of a
      // pocket: time passes, nothing is drawn.
      bool? outcome;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stationRepositoryProvider.overrideWith(
              (ref) async => StationRepository.parse(stationsJson),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  outcome = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => PreparingFlow(
                        destinationName: 'Kalyan',
                        report: clear,
                        announcer: _RecordingAnnouncer(spokenLines),
                      ),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // One pump that jumps the whole window, so the ring is never ticked
      // through it.
      await tester.pump(commitWindow);
      await tester.pumpAndSettle();

      expect(
        outcome,
        isTrue,
        reason: 'the ride must start with nobody watching',
      );
    });

    testWidgets('a warned rider passes through the window too', (tester) async {
      // Pressing Start past a volume warning confirms the WARNING, not the
      // destination. One exit from this flow starts a ride, and it is the
      // window.
      spokenLines.clear();
      final outcome = await pumpFlow(
        tester,
        report: const PreparingReport(
          hasFix: true,
          originName: 'Shahad',
          backgroundLocationGranted: true,
          earphonesConnected: true,
          alarmVolume: 0.05,
        ),
        tapPreflightStart: true,
      );

      expect(outcome, isTrue);
      expect(spokenLines, hasLength(1));
    });
  });
}

/// Earphones always in, answering instantly.
///
/// The REAL gateway cannot be used here: `AudioSession.instance` never resolves
/// under the widget-test binding, and unlike the getDevices call inside it there
/// is no timeout on that await. That hang is what these tests found, and it is
/// now bounded in the flow itself.
class _EarphonesIn implements AudioOutputGateway {
  const _EarphonesIn();

  @override
  Future<bool> earphonesConnected() async => true;
}

/// Records what the commit window said, and says nothing itself.
class _RecordingAnnouncer extends CommitAnnouncer {
  _RecordingAnnouncer(this.lines);

  final List<String> lines;

  @override
  Future<bool> speak(String line, {required AppLanguage language}) async {
    lines.add(line);
    return true;
  }
}
