import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry, and the rules that keep a rider's journey out of it.
///
/// WHY THIS EXISTS: the app runs on two phones here and will run on hundreds
/// that behave differently. The failures worth catching are the ones that
/// cannot be reproduced at this desk, above all an OEM that kills the
/// foreground service mid-ride. Without a stack trace those arrive as a one
/// star review, which teaches nothing.
///
/// WHAT MUST NEVER LEAVE THE DEVICE: where the rider is, or was, or is going.
/// That is the Phase 4 privacy note and it is not negotiable for a crash
/// reporter either, so this file spends more code on removing data than on
/// sending it. Three defences, in order:
///
///   1. Nothing is collected automatically. Print breadcrumbs are OFF, so the
///      ride log (which is full of `FIX lat ..., lng ...`) is never swept up.
///      Screenshots and view hierarchies are OFF too, because Screen 4 draws
///      the whole chain and a screenshot of it is a journey.
///   2. [scrubLocation] runs over every event that does go out, in case a
///      coordinate reached an exception message by a route nobody predicted.
///      That is the one this project should trust least and test most.
///   3. Breadcrumbs that carry a coordinate are dropped whole rather than
///      scrubbed, because a breadcrumb is context and context that had to be
///      censored is not worth sending.
///
/// THE DSN IS NOT IN THE TREE. The repository is public, so it arrives through
/// `--dart-define-from-file=secrets.json` (gitignored, see `docs/sentry.md`) on
/// a local build, and from a repository secret in CI. With no DSN this class
/// does nothing at all and the app runs normally, which is what every clone and
/// every test gets.
///
/// AN EMPTY DSN IS COMPILED OUT, NOT SWITCHED OFF. [dsn] is a const from the
/// environment, so `isEnabled` is a compile-time constant and the AOT compiler
/// deletes everything behind it, including [sendTestEvent]'s success message.
/// That is how the 9 Aug IPA was diagnosed a day later, from strings in the
/// binary: a build with a real DSN contains "Sent to Sentry:", a dark one keeps
/// only "Crash reporting is OFF". Useful, and worth knowing before trusting a
/// scan of a build for a key.
class CrashReporting {
  const CrashReporting._();

  /// Supplied at build time. Empty in every checkout, and empty is a valid
  /// state: it means crash reporting is off, not that something failed.
  static const dsn = String.fromEnvironment('SENTRY_DSN');

  static bool get isEnabled => dsn.isNotEmpty;

  /// Brings crash reporting up for the UI isolate, and NEVER HOLDS THE FIRST
  /// FRAME. Call it AFTER `runApp`, without awaiting it.
  ///
  /// THIS USED TO WRAP `runApp` in SentryFlutter's `appRunner`, and on 10 Aug
  /// 2026 that cost the whole app on iOS: the first IPA ever built with a real
  /// DSN showed a WHITE SCREEN forever and never reached the home screen, while
  /// the same commit started normally on the 3T. A build with the DSN left out
  /// and the Aptabase key kept opened immediately, which is what identified the
  /// culprit.
  ///
  /// The mechanism is in the package, not in our options. `Sentry._init`
  /// (sentry 9.26.0) does:
  ///
  ///     await _callIntegrations(integrations, options);
  ///     await appRunner();
  ///
  /// Every integration is awaited BEFORE the app runs, with no timeout around
  /// the loop, and one of them initialises the native SDK over a method channel.
  /// So an integration that never returns is an app that never draws.
  ///
  /// This is the same rule the rest of the project already follows, and the UI
  /// isolate was the one place it had never been applied: `Aptabase.init` is
  /// fired and forgotten, [initServiceIsolate] is awaited but bounded, and
  /// `_EntryGate` ignores the analytics boot on purpose. Nothing that observes a
  /// ride may prevent one.
  ///
  /// WHAT THIS COSTS, stated plainly: an error thrown in the first few hundred
  /// milliseconds, before init finishes, is not reported, and the zone-based
  /// capture that `appRunner` provides is gone. `FlutterError.onError` and
  /// `PlatformDispatcher.instance.onError` are still installed by Sentry's own
  /// default integrations once init completes, so everything after startup is
  /// still caught. A report is worth less than the screen, every time.
  static Future<void> startUiIsolate() async {
    if (!isEnabled) return;
    _uiInit = 'starting';
    try {
      await SentryFlutter.init((options) {
        _configure(options, isolate: 'ui');
        configureFlutterOnly(options);
      }).timeout(uiInitTimeout);
      _uiInit = 'ready';
    } on TimeoutException {
      // An integration that never returned. Distinct from a throw, and the
      // distinction is the whole point: one is a hang, the other is an error
      // with a name.
      _uiInit = 'still hung after ${uiInitTimeout.inSeconds}s';
    } catch (error) {
      // NOT SWALLOWED ANY MORE, and the first version of this fix did swallow
      // it. On 10 Aug the iPhone opened correctly with the DSN compiled in and
      // then reported an empty event id, which means the SDK was never up, and
      // this catch block held the only description of why. An instrument that
      // hides the cause of the fault it exists to find is not an instrument.
      _uiInit = 'failed: $error';
    }
  }

  /// The settings that exist only on [SentryFlutterOptions], and therefore only
  /// on the UI isolate: the service isolate runs the pure Dart [Sentry.init]
  /// and never touches the native SDKs.
  ///
  /// Separated from the init closure so a test can hold a real options object
  /// and read the values back. A comment claiming a collector is off is not
  /// evidence; a defaulted flag that a future SDK flips is exactly the failure
  /// this file exists to prevent.
  @visibleForTesting
  static void configureFlutterOnly(SentryFlutterOptions options) {
    // Flutter-only collectors, and both of them can see a journey: Screen 4
    // draws the whole chain, so a screenshot of it IS the rider's route, and
    // the view hierarchy carries every station name on screen.
    options.attachScreenshot = false;
    // Experimental in the SDK, and set anyway: if it is removed the build
    // breaks here loudly, which is the correct way for this particular setting
    // to fail.
    // ignore: experimental_member_use
    options.attachViewHierarchy = false;

    // WATCHDOG TERMINATION TRACKING IS OFF, and this one is not about privacy.
    // It is here because it KILLED THE APP.
    //
    // 11 Aug 2026, 13:33:35, from the iPhone's own report: `0x8BADF00D`,
    // `WatchdogEvent: process-exit`, "Failed to terminate gracefully after
    // 5.0s", thermal level 0 so heat was not the cause. The main thread was in
    //
    //     -[UIApplication _terminateWithStatus:] -> NSNotificationCenter ->
    //     -[SentryAppStateManager updateAppState:] ->
    //     [SentryFileManager storeAppState:] -> NSData._writeData -> write
    //
    // That is this feature: `storeAppState` IS the watchdog-termination
    // detector, and it writes SYNCHRONOUSLY, on the main thread, at every
    // lifecycle transition. The termination budget is about five seconds and
    // the app was spending it twice, once here and once on the service's
    // farewell.
    //
    // WHAT TURNING IT OFF COSTS: a report this project has PROVED it never
    // receives. The Cocoa SDK drops watchdog terminations that happened in the
    // BACKGROUND, and both of this app's kills were in the background. Checked
    // against the dashboard on 18 Aug 2026: the only issue there was our own
    // test event. The app counts these itself instead, as
    // `RideOutcome.interrupted` on the existing `ride_ended` event.
    //
    // iOS ONLY. The SDK documents it as "Out of Memory Tracking for iOS and
    // macCatalyst", and it reaches the native side over the method channel at
    // init. Android is untouched.
    //
    // IT IS NOT A PROMISE. This deletes one cost paid for nothing. At thermal
    // level 7 the main thread can still stall inside a transition, which is
    // what the state-preservation overrides in `AppDelegate.swift` address.
    options.enableWatchdogTerminationTracking = false;
  }

  /// How long the UI isolate's init is given before it is abandoned. Generous,
  /// because nothing is waiting for it.
  static const uiInitTimeout = Duration(seconds: 20);

  /// What happened to the UI isolate's init, in words, for the debug screen.
  ///
  /// Deliberately a string rather than an enum: its only reader is a human
  /// looking at a phone that will not report, and the useful part is the
  /// platform's own error text, which no closed set can hold.
  static String _uiInit = 'not started';

  static String get uiInitState => _uiInit;

  /// Reports the SERVICE isolate, where the ride actually runs.
  ///
  /// Uses the pure Dart [Sentry.init] rather than SentryFlutter's, because
  /// this runs in a background isolate spawned by the foreground service and
  /// has no business touching Flutter's native bindings a second time.
  ///
  /// Errors here are the interesting ones. This isolate has no screen, so a
  /// crash in it is silent: the ride simply stops watching, and the rider
  /// learns about it by missing their stop.
  static Future<void> initServiceIsolate() async {
    if (!isEnabled) return;
    await Sentry.init((options) => _configure(options, isolate: 'service'));
  }

  /// Sends one deliberate error, so a build can prove its DSN reaches Sentry.
  ///
  /// Worth a debug button because the failure mode of crash reporting is
  /// SILENCE: a wrong DSN, a missing define or a blocked network all look
  /// exactly like an app that has not crashed. Returns what to show the
  /// person who pressed it.
  /// THREE STATES, NOT TWO, and the 10 Aug iPhone is why.
  ///
  /// This used to answer an empty event id with "Sentry rejected the event.
  /// Check the DSN", which sent the reader after the one thing that was not
  /// wrong: the same DSN was reporting from Android the same evening. An empty
  /// id means the SDK IS NOT UP, and the SDK not being up has a cause, which
  /// [uiInitState] now holds. A wrong DSN and a failed init are different faults
  /// and must not share a sentence.
  static Future<String> sendTestEvent() async {
    if (!isEnabled) {
      return 'Crash reporting is OFF: no DSN in this build.';
    }
    final id = await Sentry.captureMessage(
      'Test event from the debug screen',
      level: SentryLevel.info,
    );
    if (id != const SentryId.empty()) return 'Sent to Sentry: $id';
    return 'No event id. DSN is compiled in, so the SDK is not up: '
        '$uiInitState';
  }

  static void _configure(SentryOptions options, {required String isolate}) {
    options.dsn = dsn;
    options.tracesSampleRate = 0;

    // Every automatic collector that could see a journey, turned off by name
    // rather than left to a default that may change in a future SDK. The two
    // Flutter-only ones are switched off beside the UI init, which is the only
    // place they exist.
    options.enablePrintBreadcrumbs = false;
    options.sendDefaultPii = false;
    options.beforeBreadcrumb = _dropLocationBreadcrumbs;
    options.beforeSend = _scrubEvent;

    options.addIntegration(
      // Which isolate a crash came from is the first question anyone will ask
      // of a report from this app, and Sentry cannot work it out by itself.
      _TagIntegration(isolate),
    );
  }

  static Breadcrumb? _dropLocationBreadcrumbs(Breadcrumb? crumb, Hint hint) {
    if (crumb == null) return null;
    final message = crumb.message;
    if (message != null && looksLikeLocation(message)) return null;
    return crumb;
  }

  static SentryEvent? _scrubEvent(SentryEvent event, Hint hint) {
    final message = event.message;
    if (message != null) {
      event.message = SentryMessage(
        scrubLocation(message.formatted),
        template: message.template == null
            ? null
            : scrubLocation(message.template!),
        params: message.params
            ?.map((p) => p is String ? scrubLocation(p) : p)
            .toList(),
      );
    }
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final value = exception.value;
      if (value != null) exception.value = scrubLocation(value);
    }
    return event;
  }

  /// Coordinates as this app writes them, in the shapes it actually produces.
  ///
  /// Matched against the real ride log rather than invented: `FIX lat
  /// 19.2358216, lng 73.1308101, accuracy 12m` is the line every ride writes
  /// thousands of times, and `LatLng(...)` is how the geofencing package
  /// prints a region centre in its errors.
  static final _latLngLabelled = RegExp(
    r'\b(lat|lng|latitude|longitude)\s*[:=]?\s*-?\d{1,3}\.\d+',
    caseSensitive: false,
  );
  static final _latLngConstructor = RegExp(
    r'LatLng\s*\([^)]*\)',
    caseSensitive: false,
  );
  static final _barePair = RegExp(r'-?\d{1,3}\.\d{4,},\s*-?\d{1,3}\.\d{4,}');

  /// True when [text] contains something that could be a position.
  static bool looksLikeLocation(String text) =>
      _latLngLabelled.hasMatch(text) ||
      _latLngConstructor.hasMatch(text) ||
      _barePair.hasMatch(text);

  /// Replaces every coordinate in [text] with a marker, and keeps the rest.
  ///
  /// A REDACTION, NOT A DELETION. "Geofencing error: permission denied at
  /// [location removed]" is still a usable report; dropping the whole string
  /// would throw away the only sentence that says what went wrong.
  static String scrubLocation(String text) => text
      .replaceAll(_latLngConstructor, 'LatLng([location removed])')
      .replaceAll(_barePair, '[location removed]')
      .replaceAllMapped(
        _latLngLabelled,
        (m) => '${m.group(1)} [location removed]',
      );
}

/// Tags every event with the isolate it came from.
class _TagIntegration extends Integration<SentryOptions> {
  _TagIntegration(this.isolate);

  final String isolate;

  @override
  void call(Hub hub, SentryOptions options) {
    hub.configureScope((scope) => scope.setTag('isolate', isolate));
  }
}
