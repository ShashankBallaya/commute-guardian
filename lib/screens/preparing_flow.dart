import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../services/audio_output_gateway.dart';
import '../services/commit_announcer.dart';
import '../services/permissions_gateway.dart';
import '../services/spoken_copy.dart';
import '../state/journey_providers.dart';
import '../state/ride_providers.dart';
import '../state/settings_providers.dart';
import 'preparing_screen.dart';

/// Screen 3, wired: everything that has to be true before a rider pockets the
/// phone, in order, ending in a ride or in the rider backing out.
///
/// THE GATE DECIDES BEFORE IT SHOWS. [PreparingGate.check] runs the cheap
/// probes first, and when they all pass this flow is never pushed at all, so
/// the common ride goes straight from the pick to a running ride with no
/// screen in between. That matters more than it sounds: the fix is normally
/// already held (Screen 1 acquires one on open), so a flow that pushed itself
/// unconditionally would flash a progress screen for a few hundred
/// milliseconds on every single journey, which is worse than not existing.
///
/// Pops TRUE to start the ride, FALSE (or null, on a system back) to abandon.
class PreparingFlow extends ConsumerStatefulWidget {
  const PreparingFlow({
    super.key,
    required this.destinationName,
    required this.report,
    this.permissions = const PermissionsGateway(),
    this.audio = const AudioOutputGateway(),
    this.announcer,
  });

  final String destinationName;
  final PreparingReport report;
  final PermissionsGateway permissions;
  final AudioOutputGateway audio;

  /// Speaks the commit window's one line. Injected so a test can hear what was
  /// said without a TTS engine, and null in production, where the flow builds
  /// its own.
  final CommitAnnouncer? announcer;

  @override
  ConsumerState<PreparingFlow> createState() => _PreparingFlowState();
}

enum _Stage { locating, notLocated, backgroundLocation, preflight, committing }

/// How long the rider has to take a ride back before it becomes one.
///
/// THREE SECONDS, AND IT IS THE SPOKEN LINE THAT SETS IT, not the Fitness app.
/// Two was the first answer, on the reasoning that a commuter meets this twice
/// a day and 3 s of enforced waiting is something people learn to resent. Then
/// the line went in: "Starting Travel Mode, from Dadar to Kalyan" runs about
/// three seconds, and Android's first utterance of a ride pays a 500 to 900 ms
/// cold start on top. A window shorter than its own sentence would cut the
/// only confirmation the eyes-free rider gets, which is the entire reason the
/// window speaks.
const commitWindow = Duration(seconds: 3);

class _PreparingFlowState extends ConsumerState<PreparingFlow>
    with SingleTickerProviderStateMixin {
  late _Stage _stage;
  String? _originName;

  /// The commit window's clock, running 1.0 down to 0.0. ONE controller drives
  /// both the ring the rider watches and the moment the ride begins, so the
  /// two can never disagree about how long is left.
  ///
  /// BUILT IN initState, NOT `late final`, and the difference is a real bug
  /// rather than a style. Lazily, the first access on a flow the rider backed
  /// out of is `dispose()` itself, which then creates a Ticker against a
  /// deactivated element: "Looking up a deactivated widget's ancestor is
  /// unsafe". Every path that never reaches the window took it.
  late final AnimationController _window;

  /// Set when the rider cancels, so a speech future that settles afterwards
  /// cannot start a ride nobody wants.
  bool _cancelled = false;

  /// The commit deadline, and the only thing that decides when the ride
  /// begins. Held so cancel and dispose can put it down: a live timer outliving
  /// this screen is a ride waiting to start behind the rider's back, and in a
  /// widget test it is a failure with a stack trace pointing nowhere useful.
  Timer? _deadline;
  Completer<void>? _windowClosed;

  bool _earphonesConnected = true;
  bool _volumeLow = false;
  RecheckState _recheck = RecheckState.idle;

  @override
  void initState() {
    super.initState();
    _window = AnimationController(
      vsync: this,
      duration: commitWindow,
      value: 1,
    );
    _earphonesConnected = widget.report.earphonesConnected;
    _volumeLow = widget.report.volumeLow;
    if (widget.report.hasFix) {
      _originName = widget.report.originName;
      _stage = _afterFix();
      // SETTLE FROM HERE TOO, since 26 Aug 2026. This used to be reachable
      // only through _locate, because a report with a fix and no warnings
      // never pushed this flow at all: the gate started the ride instead. Now
      // the flow is always pushed, so a clear report arrives HERE and would
      // otherwise sit on the preflight screen waiting for a Start nobody needs
      // to press. A microtask because setState may not run inside initState.
      Future.microtask(() {
        if (mounted) _settleIfClear();
      });
    } else {
      _stage = _Stage.locating;
      Future.microtask(_locate);
    }
  }

  /// What is left to ask once the origin is known.
  _Stage _afterFix() {
    if (!widget.report.backgroundLocationGranted) {
      return _Stage.backgroundLocation;
    }
    return _Stage.preflight;
  }

  Future<void> _locate() async {
    // WAIT FOR THE STATIONS FIRST. locate() returns early and silently when the
    // repository has not loaded, leaving the state on "locating", which this
    // method would otherwise read as a failed fix and answer with "We can't
    // find you yet". A rider who picked a destination before the asset finished
    // parsing would have been told GPS failed when it was never asked.
    try {
      await ref.read(stationRepositoryProvider.future);
    } catch (_) {
      if (mounted) setState(() => _stage = _Stage.notLocated);
      return;
    }
    if (!mounted) return;

    await ref.read(nearestStationProvider.notifier).locate();
    if (!mounted) return;
    final fix = ref.read(nearestStationProvider);
    if (fix.state != GpsState.located) {
      setState(() => _stage = _Stage.notLocated);
      return;
    }
    // The origin is ALREADY SET by now: locate() goes through applyFix, which
    // is the one gate for every fix source and fills the origin itself when the
    // rider has not picked one. Setting it again here would be a second writer
    // on the same field.
    setState(() {
      _originName = fix.stationName;
      _stage = _afterFix();
    });
    _settleIfClear();
  }

  /// Nothing is left to ask, so the ride is offered rather than started.
  ///
  /// THIS USED TO POP TRUE AND BEGIN THE RIDE. It opens the commit window
  /// instead: the last three seconds in which a mis-tap is still free. See
  /// [StartingScreen].
  void _settleIfClear() {
    if (_stage == _Stage.preflight && _earphonesConnected && !_volumeLow) {
      setState(() => _stage = _Stage.committing);
      unawaited(_runCommitWindow());
    }
  }

  /// The window: speak the route, run the ring, and commit if nobody objects.
  ///
  /// THE SPEECH IS AWAITED BEFORE THE POP, and that is the invariant that lets
  /// this app own two TTS engines at all. Popping true starts the service,
  /// which configures the shared audio session; doing that under a live
  /// utterance from the other engine is exactly what wedged the iPhone
  /// announcer on 21 Aug 2026 and cost that ride nine minutes of
  /// announcements. [CommitAnnouncer.speak] is bounded, so a silent engine
  /// delays a ride by a second, never forever.
  Future<void> _runCommitWindow() async {
    final language = ref.read(appSettingsProvider).valueOrNull?.language;
    final copy = SpokenCopy(language ?? AppLanguage.english);
    final announcer = widget.announcer ?? CommitAnnouncer();

    final spoken = announcer.speak(
      copy.startingRoute(
        // The origin is known by now: this stage is only reachable through a
        // landed fix. The fallback is defensive and never spoken in practice.
        origin: _originName ?? '',
        destination: widget.destinationName,
      ),
      language: language ?? AppLanguage.english,
    );

    // THE RING IS THE PICTURE. THE TIMER IS THE CLOCK, and they are separate
    // on purpose. Flutter MUTES TICKERS when the app stops producing frames,
    // which is what happens the instant a rider pockets the phone. Gating the
    // commit on the controller meant a rider who tapped Start and put the
    // phone away got no ride at all, which is the one behaviour this whole
    // product exists for. A Timer fires whether or not anything is drawn.
    //
    // REVERSE, because the controller starts full and empties. The ring shows
    // time remaining, so its value IS the controller's.
    unawaited(_window.reverse().orCancel.catchError((Object _) {}));
    final closed = Completer<void>();
    _windowClosed = closed;
    _deadline = Timer(commitWindow, () {
      if (!closed.isCompleted) closed.complete();
    });
    await closed.future;
    if (!mounted || _cancelled) return;
    await spoken;
    if (!mounted || _cancelled) return;
    Navigator.of(context).pop(true);
  }

  /// The rider took it back. Nothing has started, so nothing has to be undone:
  /// no service, no `ride_started`, no History row, no in-flight flag.
  ///
  /// THE UTTERANCE IS NOT STOPPED. iOS sends no `didCancel` for `tts.stop()`,
  /// so stopping one is a completion that never arrives. It finishes into a
  /// disposed widget, which costs a second of trailing audio and nothing else.
  void _cancelCommit() {
    _cancelled = true;
    _closeWindow();
    Navigator.of(context).pop(false);
  }

  /// Puts the clock down. Safe to call twice.
  void _closeWindow() {
    _window.stop();
    _deadline?.cancel();
    _deadline = null;
    final closed = _windowClosed;
    _windowClosed = null;
    if (closed != null && !closed.isCompleted) closed.complete();
  }

  /// Both audio probes, because Recheck is one button and the rider may have
  /// fixed either. Turning the volume up and being told only about earphones
  /// would read as the button not working.
  ///
  /// AND IT SAYS WHAT IT DID, added 11 Aug 2026. The probes return in
  /// milliseconds, so a correct answer used to arrive before the rider's finger
  /// left the glass, and if nothing had changed the screen was byte-identical.
  /// The only reasonable conclusion was that the button did nothing. See
  /// [RecheckState].
  Future<void> _recheckAudio() async {
    if (_recheck != RecheckState.idle) return;
    setState(() => _recheck = RecheckState.checking);

    final startedAt = DateTime.now();
    // BOUNDED, because a probe that never answers would strand this control on
    // "Checking…" for the rest of the ride. earphonesConnected times out its
    // own getDevices call but NOT `AudioSession.instance`, which is the await
    // that hangs under the widget-test binding and could hang on a device in a
    // state nobody has met yet. Falling back to the values already on screen
    // means a timeout reads as "no change", which is the honest answer: we
    // asked and learned nothing.
    //
    // NULL means the probe did not answer, and a probe that did not answer must
    // change NOTHING. Returning "volume unreadable" on a timeout would clear a
    // warning that is still true, which is the one direction this screen must
    // never fail in.
    final probe = await Future.wait([
      widget.audio.earphonesConnected(),
      ref.read(rideServiceClientProvider).alarmVolume(),
    ]).timeout(const Duration(seconds: 3), onTimeout: () => const []);

    final answered = probe.isNotEmpty;
    final connected = answered ? probe[0] as bool : _earphonesConnected;
    final volume = answered ? probe[1] as double? : null;
    final volumeLow = answered
        ? volume != null && volume < AudioOutputGateway.lowVolume
        : _volumeLow;
    final changed = connected != _earphonesConnected || volumeLow != _volumeLow;

    // Hold "Checking…" long enough to be seen. Measured from the tap, so a slow
    // probe waits no longer than it already took.
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = PreflightScreen.recheckMinimum - elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    if (!mounted) return;

    setState(() {
      _earphonesConnected = connected;
      _volumeLow = volumeLow;
      // A change speaks for itself: the row disappears and the headline counts
      // one fewer. Only an unchanged answer needs words, because that is the
      // case where the screen would otherwise look untouched.
      _recheck = changed ? RecheckState.idle : RecheckState.unchanged;
    });
    _settleIfClear();

    if (!changed) {
      await Future<void>.delayed(PreflightScreen.recheckSettle);
      if (!mounted) return;
      setState(() => _recheck = RecheckState.idle);
    }
  }

  @override
  void dispose() {
    _closeWindow();
    _window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destination = widget.destinationName;

    return switch (_stage) {
      _Stage.locating => PreparingScreen(
        originName: _originName,
        destinationName: destination,
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
        onCancel: () => Navigator.of(context).pop(false),
      ),
      _Stage.notLocated => CannotLocateScreen(
        originName: _originName,
        destinationName: destination,
        onRetry: () {
          setState(() => _stage = _Stage.locating);
          unawaited(_locate());
        },
        // NOTE: there is no manual origin picker yet, so this returns the
        // rider to where they came from rather than opening one. It is the
        // one control on Screen 3 that does not yet do what it says.
        onSetStation: () => Navigator.of(context).pop(false),
      ),
      _Stage.backgroundLocation => BackgroundLocationScreen(
        originName: _originName,
        destinationName: destination,
        onOpenSettings: () async {
          await widget.permissions.openSettings();
          if (context.mounted) Navigator.of(context).pop(false);
        },
        onStartAnyway: () {
          setState(() => _stage = _Stage.preflight);
          _settleIfClear();
        },
      ),
      _Stage.preflight => PreflightScreen(
        originName: _originName,
        destinationName: destination,
        steps: [
          if (!_earphonesConnected)
            const PrepStep(
              label: "Your earphones aren't connected",
              detail: 'The alarm will play out loud',
              status: PrepStatus.active,
            ),
          if (_volumeLow)
            PrepStep(
              // NAMES THE DEVICE IT MEASURED since 12 Aug 2026, and the reason
              // is a live failure mode rather than pedantry. `alarmVolume()`
              // reads AVAudioSession.outputVolume, which is the volume of the
              // CURRENT OUTPUT ROUTE. With earphones connected it describes the
              // EARPHONES and says nothing about the phone's own speaker.
              //
              // That matters because of the failure this check exists for. The
              // owner's iPhone media volume is always zero (11 Aug, the silent
              // alarm). A rider starts with earphones in and a healthy reading,
              // the earphones run out of battery an hour into a commute, the
              // alarm falls back to a speaker at zero, and the check said they
              // were fine. iOS gives no way to read the built-in speaker while
              // routed to Bluetooth, so the app cannot fix this. It can stop
              // implying it measured something it did not.
              label: _earphonesConnected
                  ? 'Your earphone volume is low'
                  : 'Volume is low',
              // Says what to do, and does not name a number. The rider cannot
              // see a percentage on their own slider, so a threshold in the
              // copy would be advice they cannot act on.
              detail: 'Turn it up, or the alarm may not wake you',
              status: PrepStatus.active,
            ),
          // REMOVED 27 Aug 2026: a row whose condition was the exact condition
          // for leaving this screen.
          //
          // It read "Checked your earphone volume / Your phone's own volume
          // isn't visible while they're connected" and drew only when
          // `_earphonesConnected && !_volumeLow`, which is what
          // `_settleIfClear` tests before moving straight to the commit
          // window. So it could never be read, and it had been unreachable
          // before the window existed too: the flow used to skip itself
          // entirely on a clear report.
          //
          // THE FACT IT CARRIED IS STILL TRUE AND STILL HAS NO HOME.
          // `alarmVolume()` reads the CURRENT OUTPUT ROUTE, so with earphones
          // connected it describes the earphones and says nothing about the
          // speaker the alarm falls back to when they die mid-commute (the
          // 11 Aug silent alarm, on a phone whose media volume is always
          // zero). Screen 1's readiness card is the surface that could say it
          // to a rider who is not already mid-Start. Deleting the row does not
          // shrink what the app knows, it stops the app claiming a disclosure
          // it never made.
          PrepStep(label: 'Watching for $destination', status: PrepStatus.done),
        ],
        // THROUGH THE WINDOW, like the clear path. A rider who pressed Start
        // past a volume warning has confirmed the WARNING, not the
        // destination, and the mis-tap this window catches is the destination.
        // One exit from this flow starts a ride, and it is the window.
        onStart: () {
          setState(() => _stage = _Stage.committing);
          unawaited(_runCommitWindow());
        },
        onRecheck: () => unawaited(_recheckAudio()),
        recheckState: _recheck,
      ),
      _Stage.committing => StartingScreen(
        originName: _originName,
        destinationName: destination,
        remaining: _window,
        onCancel: _cancelCommit,
      ),
    };
  }
}

/// What the cheap probes found. Built by [PreparingGate.check].
class PreparingReport {
  const PreparingReport({
    required this.hasFix,
    required this.originName,
    required this.backgroundLocationGranted,
    required this.earphonesConnected,
    this.alarmVolume,
  });

  final bool hasFix;
  final String? originName;
  final bool backgroundLocationGranted;
  final bool earphonesConnected;

  /// How loud the wake alarm will be, 0.0 to 1.0, or null when the platform
  /// would not say. Null is NOT a warning: see [AudioOutputGateway.alarmVolume].
  final double? alarmVolume;

  /// The rider's volume is low enough that the alarm may not wake them.
  ///
  /// ADDED 11 Aug 2026, and it was specified from the start and never built.
  /// This file's own doc listed "(earphones or volume)" as the two audio
  /// checks, and the debug screen has carried a "Volume is low" chip since
  /// Screen 3 was drawn, wired to nothing, because nothing in the app had ever
  /// read the system volume. So a rider with the volume down started a ride,
  /// saw no warning, and slept through an alarm that played into silence while
  /// every log line reported success.
  bool get volumeLow {
    final volume = alarmVolume;
    return volume != null && volume < AudioOutputGateway.lowVolume;
  }

  /// Nothing to show. The ride starts and Screen 3 never appears, which is the
  /// normal case.
  bool get clear =>
      hasFix && backgroundLocationGranted && earphonesConnected && !volumeLow;
}

/// Runs the probes that decide whether Screen 3 is needed at all.
class PreparingGate {
  const PreparingGate({
    this.permissions = const PermissionsGateway(),
    this.audio = const AudioOutputGateway(),
  });

  final PermissionsGateway permissions;
  final AudioOutputGateway audio;

  Future<PreparingReport> check(WidgetRef ref) async {
    final fix = ref.read(nearestStationProvider);
    final hasFix = fix.state == GpsState.located;
    final granted = await permissions.hasAlways();
    final earphones = await audio.earphonesConnected();
    final volume = await ref.read(rideServiceClientProvider).alarmVolume();
    return PreparingReport(
      hasFix: hasFix,
      originName: hasFix ? fix.stationName : null,
      backgroundLocationGranted: granted,
      earphonesConnected: earphones,
      alarmVolume: volume,
    );
  }
}
