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
/// Deliberately a closed set of five words. Anything richer (which station,
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

  /// Ended before arriving, because the rider pressed End.
  ///
  /// THIS COMMENT USED TO SAY the rider and the OS were "indistinguishable from
  /// in here and not worth separating". Both halves were wrong, and 16 Aug 2026
  /// is what proved it: iOS killed a ride on the way home from CSMT and the
  /// journey simply vanished, counted here as nothing at all. Since `74f5e75`
  /// the store CAN tell the two apart, and [interrupted] is the difference.
  endedEarly,

  /// THE APP DIED MID-RIDE AND THE RIDER CAME BACK TO FIND OUT.
  ///
  /// Reported from the UI isolate at the moment the rider answers the offer on
  /// Screen 1, resume or decline, which is the only moment this can be known:
  /// the process that was riding is dead, and a dead process reports nothing.
  ///
  /// WHAT IT COUNTS, exactly. Kills where the rider reopened the app inside
  /// `resumeWindow` and answered. A rider whose phone stays in their pocket is
  /// still invisible, and no event fired from this app can ever see them. So
  /// this is a FLOOR on how often Travel Mode dies, never the true rate.
  ///
  /// WHY IT IS WORTH HAVING ANYWAY. Until 18 Aug 2026 the only trace of a kill
  /// was a `ride_started` with no `ride_ended`, and that signal is confounded:
  /// of eight such orphans in the 10 to 18 Aug export, three were desk benches
  /// and one was an Aptabase session split. Two were real, and nothing said so.
  interrupted;

  String get wireName => switch (this) {
    RideOutcome.arrived => 'arrived',
    RideOutcome.overshot => 'overshot',
    RideOutcome.timeout => 'timeout',
    RideOutcome.endedEarly => 'ended_early',
    RideOutcome.interrupted => 'interrupted',
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

  /// Whether there is a key we can actually send to.
  ///
  /// SHAPE-CHECKED, NOT JUST NON-EMPTY, and the Sentry DSN is why: a secret
  /// pasted as a whole JSON line once shipped a white screen to a build nobody
  /// could use. The package asserts this same pattern, and an `assert` is
  /// stripped from the release build that ships, where the check that remains
  /// leaves `_appKey` unassigned and every send throws a
  /// `LateInitializationError` into a catch block that swallows it.
  ///
  /// So a mistyped key used to read as CONFIGURED and behave as broken. Now it
  /// reads as absent, which is a state the rest of this file already handles,
  /// and which stops [awaitQueueDrain] holding a dying isolate open for a
  /// queue that nothing was ever going to drain.
  ///
  /// `SH` is not accepted: a self-hosted key needs an `InitOptions.host` we do
  /// not pass, so the package would refuse it too.
  static bool get isConfigured {
    final parts = appKey.split('-');
    return parts.length == 3 &&
        parts.every((part) => part.isNotEmpty) &&
        const {'EU', 'US', 'DEV'}.contains(parts[1]);
  }

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
    final queue = IsolateEventQueue(isolate.name);
    pendingQueue = queue;
    // Held so events queued before init finishes still go out, and so a hung
    // init cannot leave them waiting forever.
    _ready = Aptabase.init(
      appKey,
      InitOptions(tickDuration: tickFor(isolate)),
      queue,
    ).timeout(startupTimeout).catchError((Object _) {});
    return _ready!;
  }

  /// How often the SDK looks for queued events to send. THE CANONICAL TELLING
  /// OF THE 10 SEP 2026 BUG: everything else about it cites this.
  ///
  /// THE PACKAGE'S 30 SECONDS IS WRONG FOR THE SERVICE ISOLATE, and his own
  /// dashboard is what proved it: Android rides showed `ride_started` and no
  /// `ride_ended`, and the missing ones appeared only when he started the NEXT
  /// ride.
  ///
  /// `Aptabase.trackEvent` does not send. It queues, and the queue is flushed
  /// by exactly three things: once inside `Aptabase.init`, an
  /// `AppLifecycleListener.onInactive` a headless service isolate never
  /// receives, and this timer. `ride_started` is queued at the top of a ride
  /// and the timer flushes it somewhere on the train. **`ride_ended` is queued
  /// in the isolate's dying seconds**, in `GeofenceChainService.stop()`, with
  /// only the farewell and the teardown between it and
  /// `FlutterForegroundTask.stopService()`. At 30 seconds it almost never got
  /// out, and survived only because the next ride's init found it on disk.
  ///
  /// WHY IT WAS WORSE THAN A MISSING ROW: `ride_started` with no `ride_ended`
  /// is the exact signature [RideOutcome.interrupted] reads as an OS kill.
  ///
  /// TWO SECONDS is chosen against the teardown, not against the network: the
  /// farewell alone is 2 to 3 seconds, so the tick lands inside the window the
  /// old default missed.
  ///
  /// WHAT IT COSTS, STATED HONESTLY BECAUSE IT HAS NOT BEEN MEASURED. This
  /// timer runs for the whole ride, not just the teardown, so an hour's ride
  /// pays about 1,800 wakeups instead of 120. Each one that finds an empty
  /// queue reads an in-memory map and returns. The desk reasoning is that this
  /// is nothing beside a ride that holds GPS continuously, where 18 Aug 2026
  /// measured two thirds of our whole draw as the location provider. THAT IS
  /// REASONING, NOT A MEASUREMENT. The instrument that would settle it is the
  /// same one that produced the 6.7 percent per hour figure, and the next
  /// battery bench should read this rather than assume it.
  ///
  /// THE UI ISOLATE KEEPS THE 30, deliberately. Its one ride event is
  /// [trackRideInterrupted], and the UI both gets the lifecycle flush and
  /// recovers its queue at every app open, which is far more often than a
  /// ride. A 2 second timer for the life of the foreground app buys it nothing.
  static Duration tickFor(AnalyticsIsolate isolate) => switch (isolate) {
    AnalyticsIsolate.service => const Duration(seconds: 2),
    AnalyticsIsolate.ui => const Duration(seconds: 30),
  };

  /// The queue this isolate's SDK is sending from.
  ///
  /// REAL STATE ON THE REAL PATH, written by [init], and NOT a test seam
  /// despite the annotation. [awaitQueueDrain] reads it to tell when the SDK
  /// has finished; the annotation is here only because a test also has to be
  /// able to stand one in, and there is no way to say that in Dart without
  /// making the field reachable. It is deliberately not cleared when a ride
  /// ends: the queue outlives any one ride, which is the whole point of it.
  @visibleForTesting
  static IsolateEventQueue? pendingQueue;

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

  /// A ride the OS killed, reported when the rider answers the offer.
  ///
  /// THE ONE RIDE EVENT THE UI ISOLATE IS ALLOWED TO SEND, and the exception
  /// needs saying because the rule it breaks is load-bearing: ride events come
  /// from the SERVICE isolate, because the UI can die mid-ride. Here the
  /// service is the half that died, so there is nobody else left to say so.
  ///
  /// FIRED ONCE PER KILL, at resume or decline, never at detection. Detection
  /// repeats at every launch until the rider answers, so reporting there would
  /// count one dead ride three times if they opened the app three times.
  ///
  /// [wakeArmed] and [wakeAnswered] are false, and that is a measurement
  /// decision rather than a default: the wake ladder's 95 percent bar is
  /// computed over rides where the ladder actually ran, so a ride nobody was
  /// watching must not enter that denominator. It cost the rider their alarm;
  /// it says nothing about whether the alarm works.
  Future<void> trackRideInterrupted() => trackRideEnded(
    outcome: RideOutcome.interrupted,
    wakeArmed: false,
    wakeAnswered: false,
  );

  /// Waits, once, for a queued ride event to be written AND then sent, and
  /// gives up rather than holding a dying isolate open.
  ///
  /// THE BELT TO [tickFor]'s BRACES. A timer is a probability, not a
  /// guarantee: a slow phone can still outrun a 2 second tick, or the tick can
  /// arrive while the SDK is already mid-send. The event this protects is the
  /// one that says whether the alarm worked.
  ///
  /// NOTE WHAT IT CANNOT DO. Nothing here triggers a send. `Aptabase` exposes
  /// no flush, so this waits for the SDK's own timer to drain the queue we
  /// gave it. That is why it is named for waiting and not for flushing.
  ///
  /// ONE BUDGET, NOT TWO. [queued] is the future from [trackRideEnded], which
  /// only writes the event to disk; it is awaited here rather than dropped,
  /// because dropping it raced that write against the isolate's death. Both
  /// the write and the drain come out of [limit] together, so the caller's
  /// worst case is [limit] and not twice it. A first draft gave each its own
  /// [limit] and quietly doubled the teardown.
  ///
  /// ON TIMEOUT the event is still on disk and the next ride's `Aptabase.init`
  /// sends it, which is exactly the behaviour this replaced. The worst case
  /// here is the old bug, never something worse.
  ///
  /// Returns at once when the rider has opted out, when no usable key is
  /// compiled in, or when the queue is already empty, which is the ordinary
  /// case once the tick is 2 seconds.
  Future<void> awaitQueueDrain({
    required Future<void> queued,
    Duration limit = drainLimit,
  }) async {
    if (!isActive) return;
    final giveUpAt = DateTime.now().add(limit);
    try {
      await queued.timeout(limit, onTimeout: () {});
      final queue = pendingQueue;
      if (queue == null) return;
      while (true) {
        if ((await queue.getItems(1)).isEmpty) return;
        if (!DateTime.now().isBefore(giveUpAt)) return;
        await Future<void>.delayed(pollInterval);
      }
    } catch (_) {
      // Same rule as [_send]. Counting a ride may not endanger ending one.
    }
  }

  /// The whole budget [awaitQueueDrain] may spend, disk write included.
  ///
  /// Three seconds against a farewell already allowed eight. It is spent in
  /// full only when the send is failing, which is the case where it buys
  /// nothing, and the case where the event was going to wait for the next ride
  /// anyway.
  static const drainLimit = Duration(seconds: 3);

  /// How often [awaitQueueDrain] re-reads the queue. An in-memory map read, so
  /// the cost is the wakeup and not the work.
  static const pollInterval = Duration(milliseconds: 200);

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
