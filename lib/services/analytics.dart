import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:flutter/foundation.dart';

import 'analytics_event_queue.dart';

/// Which isolate is starting the SDK. An enum rather than a string because it
/// names an event QUEUE: a typo would open a third one, silently, and the fault
/// it guards against is already invisible enough. See [IsolateEventQueue].
enum AnalyticsIsolate {
  /// Records the app open. Dies with the app, so it never reports a ride.
  ui,

  /// Where every ride event comes from, because the UI can die mid-ride.
  service,
}

/// How a ride finished. The only thing analytics ever learns about a journey.
///
/// Deliberately a closed set of four words. Anything richer (which station,
/// which line, how long) would describe a person's commute, and this file's
/// whole job is that it cannot.
enum RideOutcome {
  /// The destination was announced. The app did what it promised.
  arrived,

  /// An overshoot pin fired: the rider was carried past their stop. THE
  /// FAILURE THE PRODUCT EXISTS TO PREVENT, and the reason wake success is a
  /// pre-committed bar rather than a nice-to-have.
  overshot,

  /// The four hour backstop ended a ride nobody ended.
  timeout,

  /// Ended before arriving: the rider pressed End, or the OS took the service.
  /// The two are indistinguishable from in here and are not worth separating.
  endedEarly;

  String get wireName => switch (this) {
    RideOutcome.arrived => 'arrived',
    RideOutcome.overshot => 'overshot',
    RideOutcome.timeout => 'timeout',
    RideOutcome.endedEarly => 'ended_early',
  };
}

/// Aptabase, and the reason there are only two events in it.
///
/// WHAT THIS IS FOR. The project has five pre-committed numbers (locked
/// monetization design): 500 installs and 100 weekly active riders at three
/// months, wake success at 95 percent, D30 at 40 percent, and a kill floor of
/// under 50 weekly active or D30 under 20 percent at six months. Every one of
/// them is a RETENTION or OUTCOME measurement and NONE can be measured
/// retroactively, which is why this shipped before the beta rather than after
/// the first cohort was already lost.
///
/// So the event list is derived from that table, not from curiosity:
///
///   - installs and D30 were believed to come from Aptabase's own anonymous
///     per-device identity, with initialising the SDK as the whole
///     implementation. THAT WAS WRONG TWICE OVER, and it was wrong when it was
///     written. `Aptabase._tick` returns early when the queue is empty, so an
///     app open transmits NOTHING; the only data this app produces comes from
///     the two ride events. Installs come from the Play Console instead, which
///     was always the better source. And on identity:
///     Aptabase has NO per-device identity, deliberately: it uses no device id,
///     no cookie and no fingerprint, and the payload this file sends carries a
///     timestamp, a session id, system properties and props, and nothing else.
///     The `user_id` column in a CSV export is derived server-side from
///     something unstable; one 3T produced THREE of them in one evening on a
///     moving train (9 Aug 2026 export). So D30 at 40 percent and the D30 kill
///     floor, two of the five pre-committed bars, are NOT MEASURABLE on this
///     stack as it stands. OPEN DECISION, and an owner's one: it trades the
///     "no identifiers" position against a bar the project committed to.
///   - weekly active riders means three or more Travel Mode rides in a week, so
///     it needs [trackRideStarted] and nothing else.
///   - wake success means: of the rides where the alarm actually had to work,
///     how many ended at the destination rather than past it. That is
///     [trackRideEnded] and its outcome.
///
/// Two events. Anything else is a question nobody has committed to answering,
/// and the cost of an extra property here is not storage, it is that each one
/// is another chance to ship a rider's commute to a server.
///
/// WHAT NEVER LEAVES THE DEVICE: station ids, station names, line ids,
/// coordinates, journey duration, times of day beyond the timestamp Aptabase
/// puts on every event anyway. `analytics_test.dart` asserts the property
/// values are drawn from closed sets, because "we would notice" is not a
/// control.
///
/// OPT-OUT, not opt-in, per the locked design. The switch already existed in
/// Settings and wrote to drift before there was anything to read it; this is
/// the thing that reads it. Off means nothing initialises and nothing is sent.
class Analytics {
  Analytics({required this.enabled, Aptabase? client})
    : _client = client ?? Aptabase.instance,
      _forceConfigured = false;

  /// Behaves as though a build-time app key were present, so the send path can
  /// be exercised at all.
  ///
  /// Without this every test runs with [isConfigured] false, so [_send]
  /// returns at its first line and the guards below it are never reached: the
  /// "a broken client cannot escape into the ride" test would pass by doing
  /// nothing, which is worse than not having it.
  @visibleForTesting
  Analytics.configured({required this.enabled, required Aptabase client})
    // ignore: prefer_initializing_formals
    : _client = client,
      _forceConfigured = true;

  final bool _forceConfigured;

  /// The rider's choice, `AppSettings.shareAnonymousUsage`. Read at
  /// construction on both sides of the isolate boundary.
  final bool enabled;

  final Aptabase _client;

  /// Supplied at build time, like the Sentry DSN and for the same reason: this
  /// repository is public. Empty in every checkout, and empty means off.
  static const appKey = String.fromEnvironment('APTABASE_APP_KEY');

  static bool get isConfigured => appKey.isNotEmpty;

  /// True only when there is a key to send to AND the rider has not opted out.
  bool get isActive => (isConfigured || _forceConfigured) && enabled;

  /// IDEMPOTENT ON PURPOSE. The UI isolate boots this from a provider that
  /// re-runs whenever any setting changes, and a second init would start a
  /// second session and count one app open twice, which is the number two of
  /// the five pre-committed bars are read from.
  ///
  /// Note what this does NOT do: a rider who switches the toggle OFF mid-session
  /// cannot un-initialise the SDK, because Aptabase has no teardown. What they
  /// get is immediate, though, and it is the part that matters: every event
  /// this app sends is checked against [isActive] at the moment of sending, so
  /// no ride is reported from the instant they opt out. The session itself ends
  /// with the app.
  static bool _started = false;

  /// Starts the SDK. Safe to call when inactive: it does nothing.
  ///
  /// Called in BOTH isolates. The UI isolate's call is what records an app
  /// open, which is the entire implementation of installs and D30. The service
  /// isolate needs its own because a background isolate has its own heap and
  /// knows nothing about the UI's SDK.
  ///
  /// NEVER AWAIT THIS ON THE RIDE PATH. It returns a future so a caller that
  /// genuinely wants to wait can, but `Aptabase.init` POSTS TO THE NETWORK
  /// before it completes (it flushes any queued events at startup), the package
  /// sets no timeout, and Dart's HttpClient has none by default.
  ///
  /// This app starts rides in trains, tunnels and cuttings, on the worst
  /// networks it will ever see. An awaited init on the service isolate's
  /// onStart meant a hung socket could delay Travel Mode itself. Analytics
  /// delaying the thing that wakes a sleeping rider is the wrong way round in
  /// every possible case, so the ride path fires this and walks away.
  /// [isolate] names this isolate's own event queue. Both isolates used to share
  /// the package's single queue in SharedPreferences, and each took a snapshot of
  /// it at startup, so whichever started second ADOPTED the other's pending
  /// events and sent them again. Two of five rides in the 9 Aug 2026 export are
  /// duplicated for exactly that reason. See [IsolateEventQueue].
  static Future<void> init({
    required bool enabled,
    required AnalyticsIsolate isolate,
  }) {
    if (!isConfigured || !enabled || _started) return Future.value();
    _started = true;
    // Held so events queued before init finishes still go out, and so a hung
    // init cannot leave them waiting forever.
    _ready = Aptabase.init(
      appKey,
      const InitOptions(),
      IsolateEventQueue(isolate.name),
    ).timeout(startupTimeout).catchError((Object _) {});
    return _ready!;
  }

  /// How long an event will wait for a slow startup before giving up on
  /// itself. Bounded because the alternative is a queue of pending sends
  /// growing for the length of a ride.
  static const startupTimeout = Duration(seconds: 10);

  static Future<void>? _ready;

  /// A ride began. No properties: the count is the measurement.
  Future<void> trackRideStarted() =>
      _send(() => _client.trackEvent('ride_started'));

  /// A ride finished, and how.
  ///
  /// [wakeArmed] is what makes the 95 percent bar honest. A ride where the
  /// rider was awake the whole time and got off normally says nothing about
  /// whether the alarm works, so wake success is measured over the rides where
  /// the ladder actually ran. [wakeAnswered] then separates "the alarm woke
  /// them" from "they were already awake when it fired", which is the
  /// difference between a product that works and one that got lucky.
  Future<void> trackRideEnded({
    required RideOutcome outcome,
    required bool wakeArmed,
    required bool wakeAnswered,
  }) => _send(
    () => _client.trackEvent('ride_ended', {
      'outcome': outcome.wireName,
      'wake_armed': wakeArmed,
      'wake_answered': wakeAnswered,
    }),
  );

  /// Sends one event, and CANNOT FAIL INTO THE RIDE.
  ///
  /// Two guards, both learned from reading the package rather than from
  /// trusting it:
  ///
  ///   - it waits for [init] to finish, because `trackEvent` reads a `late
  ///     final` field and throws if the SDK has not started yet. The ride path
  ///     no longer awaits init, so that race is now real rather than
  ///     theoretical.
  ///   - it swallows everything. These calls are fired unawaited from the
  ///     start and stop of a ride, so a thrown error would surface as an
  ///     unhandled async exception in the service isolate, which is the
  ///     isolate whose death is silent. NOTHING about counting a ride may
  ///     endanger riding one.
  Future<void> _send(Future<void> Function() body) async {
    if (!isActive) return;
    try {
      await _ready;
      await body();
    } catch (_) {
      // Deliberately empty. An analytics failure is not a rider's problem, and
      // there is nowhere useful to report it from a background isolate.
    }
  }
}
