import 'dart:io';

import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:commute_guardian/services/analytics.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('every outcome is one of four fixed words', () {
      // A closed set, so a property can never carry free text that happens to
      // contain a place name.
      expect(RideOutcome.values.map((o) => o.wireName).toSet(), {
        'arrived',
        'overshot',
        'timeout',
        'ended_early',
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
      expect(source, contains('unawaited(Analytics.init('));
      expect(source, isNot(contains('await Analytics.init(')));

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
