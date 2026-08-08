import 'dart:async';

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
/// THE DSN IS NOT COMPILED IN. The repository is public, so it arrives through
/// `--dart-define-from-file=sentry.json` (gitignored, see `docs/sentry.md`).
/// With no DSN this class does nothing at all and the app runs normally, which
/// is what every clone and every test gets.
class CrashReporting {
  const CrashReporting._();

  /// Supplied at build time. Empty in every checkout, and empty is a valid
  /// state: it means crash reporting is off, not that something failed.
  static const dsn = String.fromEnvironment('SENTRY_DSN');

  static bool get isEnabled => dsn.isNotEmpty;

  /// Runs [body] with the UI isolate reported. Falls straight through to
  /// [body] when no DSN is configured.
  static Future<void> runUiIsolate(FutureOr<void> Function() body) async {
    if (!isEnabled) {
      await body();
      return;
    }
    await SentryFlutter.init((options) {
      _configure(options, isolate: 'ui');
      // Flutter-only collectors, and both of them can see a journey: Screen 4
      // draws the whole chain, so a screenshot of it IS the rider's route,
      // and the view hierarchy carries every station name on screen.
      options.attachScreenshot = false;
      // Experimental in the SDK, and set anyway: if it is removed the build
      // breaks here loudly, which is the correct way for this particular
      // setting to fail.
      // ignore: experimental_member_use
      options.attachViewHierarchy = false;
    }, appRunner: () => body());
  }

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
  static Future<String> sendTestEvent() async {
    if (!isEnabled) {
      return 'Crash reporting is OFF: no DSN in this build.';
    }
    final id = await Sentry.captureMessage(
      'Test event from the debug screen',
      level: SentryLevel.info,
    );
    return id == const SentryId.empty()
        ? 'Sentry rejected the event. Check the DSN.'
        : 'Sent to Sentry: $id';
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
