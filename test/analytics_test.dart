import 'dart:async';
import 'dart:io';

import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:commute_guardian/services/analytics.dart';
import 'package:commute_guardian/services/analytics_event_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Analytics, and the two things that can go wrong with it.
///
/// The first is that it sends something about a rider's journey. The second is
/// that it sends nothing, silently, and three months later the pre-committed
/// bars cannot be read because retention was never measurable retroactively.
/// Both are tested here; neither is left to "we would notice".
void main() {
  group('what may never leave the device', () {
    test('THE EVENT LIST IS TWO EVENTS, and the source proves it', () {
      // Enforced against the source rather than by convention, in the same
      // spirit as the isolate-boundary guard: the way this feature rots is one
      // useful-looking property at a time, and each one is another chance to
      // ship somebody's commute.
      final source = File('lib/services/analytics.dart').readAsStringSync();
      final events = RegExp(
        r"trackEvent\(\s*'([a-z_]+)'",
      ).allMatches(source).map((m) => m.group(1)).toSet();
      expect(events, {'ride_started', 'ride_ended'});
    });

    test('NO STATION, NO LINE, NO COORDINATE IN THE CODE', () {
      // Not an exhaustive proof, and not meant to be. It is a tripwire on the
      // words that would appear if someone added "which station did they get
      // off at" to the payload, which is the change that would look harmless
      // in review.
      //
      // TWO RULES IT LEARNED THE HARD WAY, both within an hour of being
      // written. It reads CODE, not prose, because this file's own doc comment
      // has to name the things it refuses to send. And it matches WHOLE WORDS,
      // because `lat` sits inside `isolate` and the first draft failed on its
      // own explanation. That is the identical bug the isolate-boundary guard
      // had, found the same evening, which says something about how naturally
      // this mistake is made.
      final code = _stripComments(
        File('lib/services/analytics.dart').readAsStringSync(),
      ).toLowerCase();

      for (final forbidden in const [
        'stationid',
        'station_id',
        'stationname',
        'lineid',
        'line_id',
        'lat',
        'lng',
        'latitude',
        'longitude',
        'journey',
        'destination',
        'origin',
      ]) {
        expect(
          RegExp('(?<![a-z0-9_])$forbidden(?![a-z0-9_])').hasMatch(code),
          isFalse,
          reason: 'analytics.dart uses "$forbidden" in code',
        );
      }
    });

    test('the tripwire reads code and would catch a real leak', () {
      // A guard nobody has seen fail is a guard nobody knows works.
      expect(
        _stripComments('// the destination is never sent'),
        isNot(contains('destination')),
      );
      expect(
        _stripComments('/// station_id stays here'),
        isNot(contains('station_id')),
      );
      expect(
        _stripComments("props['station_id'] = id;"),
        contains('station_id'),
      );
    });

    test('every outcome is one of five fixed words', () {
      // A closed set, so a property can never carry free text that happens to
      // contain a place name.
      //
      // WAS FOUR UNTIL 18 AUG 2026, and this test is how the fifth word was
      // reviewed rather than slipped in: adding an outcome has to fail here
      // first. 'interrupted' means the OS killed a ride and the rider came
      // back to find out. It carries no more information than the other four.
      expect(RideOutcome.values.map((o) => o.wireName).toSet(), {
        'arrived',
        'overshot',
        'timeout',
        'ended_early',
        'interrupted',
      });
    });
  });

  group('the opt-out', () {
    test('OFF SENDS NOTHING, and off is the default everywhere', () {
      // Both halves matter. A rider who opted out must send nothing, and a
      // caller that simply forgot to pass the flag must also send nothing:
      // absence of an answer is not consent.
      expect(Analytics(enabled: false).isActive, isFalse);
      expect(Analytics(enabled: true).isActive, isFalse);
    });

    test('no app key in the checkout, and that is a working state', () {
      // Same rule as the Sentry DSN: this repository is public, so the key
      // arrives at build time. Without it the app runs and reports nothing.
      expect(Analytics.appKey, isEmpty);
      expect(Analytics.isConfigured, isFalse);
    });

    test('an inactive tracker still completes its calls', () async {
      // These are awaited (or unawaited) on the ride path. A disabled tracker
      // that threw would take a ride down with it.
      final analytics = Analytics(enabled: true);
      await analytics.trackRideStarted();
      await analytics.trackRideEnded(
        outcome: RideOutcome.arrived,
        wakeArmed: true,
        wakeAnswered: true,
      );
    });
  });

  group('ANALYTICS MUST NEVER DELAY A RIDE', () {
    // Found 8 Aug 2026 by reading aptabase_flutter rather than trusting it.
    // `Aptabase.init` POSTS to the network before its future completes, the
    // package sets no timeout, and Dart's HttpClient has none by default. The
    // first wiring awaited that at the top of the service isolate's onStart,
    // which put a hung socket between a rider and Travel Mode starting, on an
    // app whose whole job is to start rides in cuttings and tunnels.

    test('the service isolate never awaits either SDK unbounded', () {
      final source = File(
        'lib/foreground/geofence_task_handler.dart',
      ).readAsStringSync();

      // Aptabase: fired and forgotten outright.
      //
      // Matched with whitespace allowed, not as one literal. The first version
      // demanded `unawaited(Analytics.init(` on a single line, so adding the
      // isolate argument reformatted the call and failed a test about network
      // timeouts. A guard that breaks on a line wrap teaches its reader to
      // reformat code to please it, which is backwards.
      expect(source, matches(RegExp(r'unawaited\(\s*Analytics\.init\(')));
      expect(source, isNot(matches(RegExp(r'await\s+Analytics\.init\('))));

      // Sentry: awaited, but bounded, because an early crash report is worth
      // two seconds and never worth a ride.
      expect(source, contains('CrashReporting.initServiceIsolate()'));
      final sentryCall = source.substring(
        source.indexOf('CrashReporting.initServiceIsolate()'),
      );
      expect(sentryCall.substring(0, 200), contains('.timeout('));
    });

    test('a send waits for readiness instead of the caller waiting', () {
      // The consequence of not awaiting init: trackEvent reads a late final
      // field and throws if the SDK has not started. The wait moved to the
      // send side, where nothing is blocked.
      final source = File('lib/services/analytics.dart').readAsStringSync();
      final send = source.substring(source.indexOf('Future<void> _send('));
      expect(send, contains('await _ready'));
      expect(send, contains('catch'));
    });

    test('a throwing client cannot escape into the ride', () async {
      // These calls are fired unawaited from the start and stop of a ride, in
      // the isolate whose death is silent. An unhandled async error there is
      // the worst possible way to learn analytics is broken.
      // .configured, not the normal constructor: with no build-time key this
      // test would otherwise return at _send's first line and prove nothing.
      final analytics = Analytics.configured(
        enabled: true,
        client: _ThrowingAptabase(),
      );
      expect(analytics.isActive, isTrue, reason: 'the send path must be live');
      await analytics.trackRideStarted();
      await analytics.trackRideEnded(
        outcome: RideOutcome.overshot,
        wakeArmed: true,
        wakeAnswered: false,
      );
    });
  });

  test('RELEASE BUILDS CAN ACTUALLY REACH THE NETWORK', () {
    // Flutter declares INTERNET in the debug and profile manifests only, so
    // the release build (the only one that ships) had no network permission
    // and both SDKs would have failed silently in front of real users. Found
    // 8 Aug 2026, before any release existed.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.INTERNET'));
  });

  group('one event queue per isolate, so a ride is counted once', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('NEITHER ISOLATE CAN SEE THE OTHER\'S PENDING EVENTS', () async {
      // The 9 Aug duplicate, reproduced as the thing that used to happen. The
      // service isolate queues a ride and has not flushed it yet; the UI
      // isolate then starts, which is what a force-stop and reopen mid-ride
      // does. Before this fix the UI's snapshot picked the event up and sent it
      // a second time, with the original timestamp.
      final service = IsolateEventQueue(AnalyticsIsolate.service.name);
      await service.init();
      await service.addEvent('aptabase_1_ride_started', '{"e":"ride_started"}');

      final ui = IsolateEventQueue(AnalyticsIsolate.ui.name);
      await ui.init();

      expect(await ui.getItems(25), isEmpty);
      expect((await service.getItems(25)).length, 1);
    });

    test('a queue recovers its own events after the isolate died', () async {
      // The other half of the rule, and the reason this is not simply "do not
      // persist". A service isolate the OS killed mid-ride must still get its
      // ride counted by the next one.
      final died = IsolateEventQueue(AnalyticsIsolate.service.name);
      await died.init();
      await died.addEvent('aptabase_1_ride_ended', '{"e":"ride_ended"}');

      final next = IsolateEventQueue(AnalyticsIsolate.service.name);
      await next.init();

      final items = await next.getItems(25);
      expect(items.map((e) => e.key), ['aptabase_1_ride_ended']);
      expect(
        items.single.value,
        '{"e":"ride_ended"}',
        reason: 'the prefix belongs to storage, never to the caller',
      );
    });

    test('a sent event is gone, from memory and from disk', () async {
      final queue = IsolateEventQueue(AnalyticsIsolate.service.name);
      await queue.init();
      await queue.addEvent('aptabase_1_ride_started', '{}');
      await queue.deleteEvents({'aptabase_1_ride_started'});

      expect(await queue.getItems(25), isEmpty);
      final reopened = IsolateEventQueue(AnalyticsIsolate.service.name);
      await reopened.init();
      expect(
        await reopened.getItems(25),
        isEmpty,
        reason: 'a delete that only cleared memory would resend on restart',
      );
    });

    test('events from the old shared queue are ignored, not adopted', () async {
      // Left on a phone by a build before this fix. Those are 9 Aug events at
      // the latest, and re-sending a stale ride is the fault being fixed.
      SharedPreferences.setMockInitialValues({
        'aptabase_1_ride_started': '{"e":"stale"}',
      });
      final queue = IsolateEventQueue(AnalyticsIsolate.service.name);
      await queue.init();

      expect(await queue.getItems(25), isEmpty);
    });

    test('BOTH ISOLATES ARE NAMED, and the enum is what names them', () {
      // A typo in a scope string would open a third queue in silence, which is
      // the same class of invisible fault as the empty secret. Read from the
      // source: every Analytics.init call site must pass an AnalyticsIsolate.
      for (final path in const [
        'lib/state/settings_providers.dart',
        'lib/foreground/geofence_task_handler.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('isolate: AnalyticsIsolate.'),
          reason: '$path must name its queue',
        );
      }
      expect(AnalyticsIsolate.values.map((i) => i.name), ['ui', 'service']);
    });
  });

  group('the outcome the bars are read from', () {
    test('AN OVERSHOOT IS NOT AN ARRIVAL', () {
      // The ordering rule in GeofenceChainService._rideOutcome, stated here
      // because it is the one that decides whether wake success means
      // anything. A ride can announce the destination AND then fire an
      // overshoot pin: the rider slept through their stop and was told about
      // it one station later. Counting that as "arrived" would report the
      // product's central failure as its central success.
      expect(RideOutcome.overshot.wireName, 'overshot');
      expect(RideOutcome.arrived.wireName, isNot('overshot'));
    });

    test('the service resolves outcomes in the right order', () {
      // Read from the source, because the getter is private and the ordering
      // IS the logic. If someone reorders these branches, an overshoot starts
      // reporting as an arrival and nothing else fails.
      final source = File(
        'lib/services/geofence_chain_service.dart',
      ).readAsStringSync();
      final body = source.substring(
        source.indexOf('RideOutcome get _rideOutcome'),
      );
      final order = RegExp(r'RideOutcome\.([a-zA-Z]+)')
          .allMatches(body.substring(0, body.indexOf('}')))
          .map((m) => m.group(1))
          .toList();
      expect(order, ['overshot', 'arrived', 'timeout', 'endedEarly']);
    });
  });

  group('A RIDE THE OS KILLED IS COUNTED, and only once', () {
    // BUILT 18 AUG 2026, after the phone's own crash reports proved iOS had
    // killed Travel Mode twice mid-ride (0x8BADF00D watchdog terminations, not
    // jetsams) and NOTHING had reported either one. Sentry cannot: its Cocoa
    // SDK deliberately drops watchdog terminations that happen in the
    // background, which both of ours were. Aptabase could only show it by
    // subtraction, and that signal is confounded: of eight rides in the 10 to
    // 18 Aug export that started and never ended, three were desk benches and
    // one was a session split.

    test('it rides the SAME two events, so the event list still holds', () {
      // The two-event guard at the top of this file is the real enforcement.
      // This says out loud that the new outcome was deliberately built as an
      // outcome rather than as a third event.
      final source = File('lib/services/analytics.dart').readAsStringSync();
      final events = RegExp(
        r"trackEvent\(\s*'([a-z_]+)'",
      ).allMatches(source).map((m) => m.group(1)).toSet();
      expect(events, {'ride_started', 'ride_ended'});
    });

    test('its wire name is stable, because a dashboard reads it', () {
      expect(RideOutcome.interrupted.wireName, 'interrupted');
    });

    test('IT STAYS OUT OF THE WAKE DENOMINATOR', () async {
      // The 95 percent bar is computed over rides where the ladder actually
      // ran. A ride nobody was watching cost the rider their alarm and says
      // nothing about whether the alarm works, so it must not dilute that bar.
      final client = _RecordingAptabase();
      await Analytics.configured(
        enabled: true,
        client: client,
      ).trackRideInterrupted();

      expect(client.events, hasLength(1));
      final (name, props) = client.events.single;
      expect(name, 'ride_ended');
      expect(props?['outcome'], 'interrupted');
      expect(props?['wake_armed'], isFalse);
      expect(props?['wake_answered'], isFalse);
    });

    test('AND IT IS SENT WHERE THE OFFER IS ANSWERED, NOT WHERE IT IS FOUND', () {
      // The counting bug this ordering prevents: an unanswered offer is
      // re-detected at EVERY launch, so reporting at detection would count one
      // dead ride once per app open. Resume and decline each happen once.
      //
      // Read from the source with comments stripped, because both call sites
      // are one line in a file this test cannot otherwise reach.
      final source = _stripComments(
        File('lib/screens/ride_orchestration.dart').readAsStringSync(),
      );

      expect(
        RegExp(r'_reportInterrupted\(\)').allMatches(source).length,
        3,
        reason:
            'exactly two call sites plus the declaration: resume and decline',
      );

      final resume = source.indexOf('Future<bool> resumeInterrupted(');
      final decline = source.indexOf('Future<void> declineInterrupted(');
      expect(resume, greaterThan(-1));
      expect(decline, greaterThan(-1));
      // Each body carries the call. Bounded by the next method so a single
      // call site cannot satisfy both.
      for (final start in [resume, decline]) {
        final body = source.substring(start, source.indexOf('\n  }', start));
        expect(
          body,
          contains('_reportInterrupted()'),
          reason: 'both ways of answering the offer must report the kill',
        );
      }

      // And NOT from the detection path, which is a provider, not this file.
      expect(
        _stripComments(
          File('lib/state/ride_providers.dart').readAsStringSync(),
        ),
        isNot(contains('trackRideInterrupted')),
        reason: 'detection repeats at every launch; reporting there over-counts',
      );
    });
  });

  group('RIDE_ENDED HAS TO LEAVE THE PHONE BEFORE THE ISOLATE DIES', () {
    // The 10 Sep 2026 bug, found on his own dashboard and confirmed from the
    // device before a line was written. Told in full on `Analytics.tickFor`,
    // which is the one place that carries it.

    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => Analytics.pendingQueue = null);

    Future<IsolateEventQueue> queueHolding(String key) async {
      final queue = IsolateEventQueue(AnalyticsIsolate.service.name);
      await queue.init();
      await queue.addEvent(key, '{"e":"ride_ended"}');
      Analytics.pendingQueue = queue;
      return queue;
    }

    test('THE SERVICE TICK IS SHORT ENOUGH TO FIRE INSIDE A TEARDOWN', () {
      // The bound that matters is not the network, it is the farewell: about 2
      // to 3 seconds of speech and then the isolate is gone. A tick slower than
      // that cannot flush the event it was queued to flush, which is what 30
      // seconds was.
      expect(
        Analytics.tickFor(AnalyticsIsolate.service),
        lessThanOrEqualTo(const Duration(seconds: 2)),
      );
      expect(
        Analytics.tickFor(AnalyticsIsolate.service),
        lessThan(Analytics.tickFor(AnalyticsIsolate.ui)),
        reason: 'the UI keeps the default: it re-sends at every app open',
      );
    });

    test('the flush returns as soon as the queue is empty', () async {
      final queue = await queueHolding('aptabase_1_ride_ended');
      // Stands in for the SDK's timer getting there while we wait.
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          () => queue.deleteEvents({'aptabase_1_ride_ended'}),
        ),
      );

      final waited = Stopwatch()..start();
      await Analytics.configured(
        enabled: true,
        client: _RecordingAptabase(),
      ).awaitQueueDrain(queued: Future<void>.value());
      waited.stop();

      expect(await queue.getItems(25), isEmpty);
      expect(
        waited.elapsed,
        lessThan(Analytics.drainLimit),
        reason: 'it must return on the drain, not sit out the whole bound',
      );
    });

    test('AND IT GIVES UP, because a dying isolate may not be held open', () async {
      // The event stays on disk and the next ride sends it, which is the old
      // behaviour. The worst case of this fix is the bug it replaces.
      final queue = await queueHolding('aptabase_1_ride_ended');
      const bound = Duration(milliseconds: 400);

      final waited = Stopwatch()..start();
      await Analytics.configured(
        enabled: true,
        client: _RecordingAptabase(),
      ).awaitQueueDrain(queued: Future<void>.value(), limit: bound);
      waited.stop();

      expect(waited.elapsed, greaterThanOrEqualTo(bound));
      expect(waited.elapsed, lessThan(const Duration(seconds: 3)));
      expect((await queue.getItems(25)).length, 1);
    });

    test('a rider who opted out is not waited on', () async {
      final queue = await queueHolding('aptabase_1_ride_ended');

      final waited = Stopwatch()..start();
      await Analytics.configured(
        enabled: false,
        client: _RecordingAptabase(),
      ).awaitQueueDrain(queued: Future<void>.value());
      waited.stop();

      expect(waited.elapsed, lessThan(const Duration(milliseconds: 200)));
      expect(
        (await queue.getItems(25)).length,
        1,
        reason: 'nothing was sent, so nothing was cleared',
      );
    });

    test('INIT ACTUALLY WIRES THE SHORT TICK, not just offers it', () {
      // THE HOLE THE SPEC REVIEW FOUND, and it is this repo's recurring one: a
      // helper can be perfectly tested and never called. Put `const
      // InitOptions()` back and every assertion about `tickFor` above still
      // passes while the fix is gone, because a pure function does not care
      // whether anybody uses it.
      final source = _stripComments(
        File('lib/services/analytics.dart').readAsStringSync(),
      );

      expect(
        source.contains('InitOptions(tickDuration: tickFor(isolate))'),
        isTrue,
        reason: 'the tick must reach Aptabase.init, not just exist',
      );
      expect(
        RegExp(r'Aptabase\.init\(\s*appKey,\s*const InitOptions\(\)')
            .hasMatch(source),
        isFalse,
        reason: 'the package default is the bug',
      );
    });

    test('AND IT HANDS INIT THE QUEUE THE DRAIN WATCHES', () {
      // The same hole, one line down. Delete `pendingQueue = queue` and
      // `awaitQueueDrain` becomes a permanent no-op in production while every
      // test above stays green, because each of them injects a queue by hand.
      final source = _stripComments(
        File('lib/services/analytics.dart').readAsStringSync(),
      );

      final assigned = source.indexOf('pendingQueue = queue;');
      final handed = source.indexOf('Aptabase.init(');
      expect(assigned, greaterThan(-1), reason: 'the drain has nothing to read');
      expect(
        assigned,
        lessThan(handed),
        reason: 'the queue the drain watches must be the one init was given',
      );
      expect(
        RegExp(r'IsolateEventQueue\(isolate\.name\)').allMatches(source).length,
        1,
        reason: 'a second queue would mean the drain watches the wrong one',
      );
    });

    test('A MISTYPED KEY READS AS ABSENT, not as configured and broken', () {
      // Found by the spec review: `pendingQueue` is set before the package can
      // reject the key, so a malformed one used to cost every ride end the full
      // budget waiting on a queue nothing would ever drain. The release build
      // is where this bites: the package's own check is an `assert`, which is
      // stripped, and the fallback leaves `_appKey` unassigned.
      //
      // The checkout has no key at all, which is the case the old
      // `isNotEmpty` already covered.
      expect(Analytics.isConfigured, isFalse);
    });

    test('THE RIDE PATH KEEPS THE EVENT AND WAITS FOR IT', () {
      // The service cannot be built in a test (plugins), so this reads the
      // source. Comments stripped, because the explanation above the call site
      // names every symbol this looks for.
      final source = _stripComments(
        File('lib/services/geofence_chain_service.dart').readAsStringSync(),
      );

      expect(
        RegExp(r'unawaited\(\s*_analytics\.trackRideEnded').hasMatch(source),
        isFalse,
        reason: 'dropping the future races the disk write against the teardown',
      );

      final queued = source.indexOf('_analytics.trackRideEnded(');
      final flushed = source.indexOf('_analytics.awaitQueueDrain(');
      expect(queued, greaterThan(-1));
      expect(flushed, greaterThan(-1), reason: 'the flush must be wired at all');
      expect(
        flushed,
        greaterThan(queued),
        reason: 'flushing before the event is queued flushes nothing',
      );
    });

    test('and that guard can still fail, proved against the old shape', () {
      // A guard nobody has watched fail is a guard that may be matching its own
      // explanation. This is the code as it stood on the morning of 10 Sep.
      const before =
          '    unawaited(\n'
          '      _analytics.trackRideEnded(\n'
          '        outcome: _rideOutcome,\n'
          '      ),\n'
          '    );\n';

      expect(
        RegExp(r'unawaited\(\s*_analytics\.trackRideEnded').hasMatch(before),
        isTrue,
        reason: 'the guard must fire on the shape it was written against',
      );
      expect(before.contains('_analytics.awaitQueueDrain('), isFalse);
    });
  });
}

/// Strips Dart comments, so a tripwire on words like "destination" can be
/// pointed at a file whose own documentation has to name them.
///
/// Same approach as `_containsBridgeCode` in isolate_boundary_test.dart, and
/// the same accepted limitation: a `//` inside a string literal truncates that
/// line early. The alternative is a Dart parser for a guard rail.
String _stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment == -1 ? line : line.substring(0, comment);
    })
    .join('\n');

/// An Aptabase whose every call fails, standing in for a dead network, a
/// rejected key, or an SDK that was never initialised.
class _ThrowingAptabase implements Aptabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<void>.error(StateError('analytics is broken'));
}

/// An Aptabase that remembers what it was asked to send.
class _RecordingAptabase implements Aptabase {
  final List<(String, Map<String, dynamic>?)> events = [];

  @override
  Future<void> trackEvent(String name, [Map<String, dynamic>? props]) async =>
      events.add((name, props));

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
