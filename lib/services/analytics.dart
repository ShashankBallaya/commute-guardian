import 'package:aptabase_flutter/aptabase_flutter.dart';

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
///   - installs and D30 come from Aptabase's own anonymous per-device identity.
///     No event. Initialising the SDK is the whole implementation.
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
    : _client = client ?? Aptabase.instance;

  /// The rider's choice, `AppSettings.shareAnonymousUsage`. Read at
  /// construction on both sides of the isolate boundary.
  final bool enabled;

  final Aptabase _client;

  /// Supplied at build time, like the Sentry DSN and for the same reason: this
  /// repository is public. Empty in every checkout, and empty means off.
  static const appKey = String.fromEnvironment('APTABASE_APP_KEY');

  static bool get isConfigured => appKey.isNotEmpty;

  /// True only when there is a key to send to AND the rider has not opted out.
  bool get isActive => isConfigured && enabled;

  /// Starts the SDK. Safe to call when inactive: it does nothing.
  ///
  /// Called in BOTH isolates. The UI isolate's call is what records an app
  /// open, which is the entire implementation of installs and D30. The service
  /// isolate needs its own because a background isolate has its own heap and
  /// knows nothing about the UI's SDK.
  static Future<void> init({required bool enabled}) async {
    if (!isConfigured || !enabled || _started) return;
    _started = true;
    await Aptabase.init(appKey);
  }

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

  /// A ride began. No properties: the count is the measurement.
  Future<void> trackRideStarted() async {
    if (!isActive) return;
    await _client.trackEvent('ride_started');
  }

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
  }) async {
    if (!isActive) return;
    await _client.trackEvent('ride_ended', {
      'outcome': outcome.wireName,
      'wake_armed': wakeArmed,
      'wake_answered': wakeAnswered,
    });
  }
}
