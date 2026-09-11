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
import 'route_picker_sheet.dart';

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
  bool _announcementsSilent = false;
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
    _announcementsSilent = widget.report.announcementsSilent;
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
    // THE SAME RULE [PreparingReport.clear] RUNS, not a second copy of it.
    // See [audioIsClear].
    if (_stage == _Stage.preflight &&
        audioIsClear(
          earphonesConnected: _earphonesConnected,
          volumeLow: _volumeLow,
          announcementsSilent: _announcementsSilent,
        )) {
      unawaited(_enterCommitWindow());
    }
  }

  /// THE ONE DOOR INTO THE COMMIT WINDOW, and it is one on purpose.
  ///
  /// Two places used to set [_Stage.committing] and start the window by hand:
  /// [_settleIfClear] for the ordinary ride and the preflight screen's own
  /// Start for a rider who pressed past a warning. C7c has to ask its question
  /// on BOTH, and a gate that only covers the path you were looking at is this
  /// project's most repeated bug. Adding a second copy of the ask was the
  /// obvious way to write it and the wrong one.
  Future<void> _enterCommitWindow() async {
    final via = await _chooseRoute();
    if (!mounted) return;
    setState(() {
      // Set WITH the stage it belongs to, so the window can never paint a
      // corridor from the journey before it.
      _viaLabel = via;
      _stage = _Stage.committing;
    });
    unawaited(_runCommitWindow());
  }

  /// What the commit window prints under the destination, or null for a ride
  /// with no change in it, which has no "which way" to answer.
  String? _viaLabel;

  /// C7c. Offers the corridors, and only when there is genuinely a choice.
  ///
  /// SILENT ON THE ORDINARY RIDE. Most journeys have exactly one route, and a
  /// sheet that opened to say so would tax every rider for a question only some
  /// of them have. Fewer than two options is not a choice.
  ///
  /// DISMISSAL IS A DECISION, NOT A DEAD END. Null comes back from the scrim,
  /// the drag and the system back, and all three mean "the one you had": the
  /// draft is left untouched, so `planAlong` falls through to `plan` and she
  /// rides exactly what a rider who never looks rides. The alternative, a sheet
  /// with no way out, would let a pocketed phone sit with no ride running and
  /// nothing said, which is worse than the bug this fixes.
  Future<String?> _chooseRoute() async {
    // WAIT FOR THE STATIONS FIRST, the same rule [_locate] runs on and for a
    // sharper reason. `routeOptionsProvider` answers `const []` while the
    // repository future is unresolved, and this method reads an empty list as
    // "no choice to offer". So on a cold launch where the rider taps a saved
    // route before the asset has parsed, the picker would silently not appear
    // and she would be given the default corridor with no question asked.
    //
    // The clear-report path never awaited it: only [_locate] did, and a report
    // with a fix skips [_locate] entirely. Found by review, and the test suite
    // was hiding it, because the harness resolved the repository by hand.
    //
    // AND IT CANNOT THROW ONTO THE RIDE PATH. The future carries the asset
    // parse, so it can fail, and an error escaping here would take the whole
    // flow down and leave the rider with no ride and no screen. A repository
    // that will not parse has already cost her the journey by another route
    // (`plannedJourneyProvider` reports it), so the only thing this can
    // usefully do is stop asking about corridors.
    try {
      await ref.read(stationRepositoryProvider.future);
    } catch (_) {
      return null;
    }
    if (!mounted) return null;
    final options = ref.read(routeOptionsProvider);
    if (options.length < 2) {
      return options.firstOrNull?.viaLabel;
    }
    final chosen = await showRoutePicker(
      context: context,
      destinationName: widget.destinationName,
      options: options,
      chosenChainIds: ref.read(journeyDraftProvider).routeChainIds,
    );
    if (!mounted) return null;
    if (chosen != null) {
      ref.read(journeyDraftProvider.notifier)
        ..setChosenRoute(chosen)
        // AND THE ORIGIN IS HERS NOW TOO, which is not tidiness but the fix
        // for a silent revert. The window runs for three more seconds with the
        // origin still `OriginSource.defaulted`, and a streamed fix in that gap
        // calls `defaultOriginTo`, which builds a fresh draft and drops
        // `routeChainIds` BY OMITTING IT. The ride would then begin on the
        // ordinary corridor while this screen still printed the one she chose.
        //
        // `confirmOrigin` is the right tool rather than a new one: it exists to
        // mark an origin as the rider's own without disturbing the rest of the
        // draft, and it was built carrying the chosen chain through for exactly
        // this reason. Choosing a corridor IS choosing where you are standing.
        ..confirmOrigin();
    }
    // READ BACK RATHER THAN ASSUMED. On a dismissal `chosen` is null and the
    // draft still holds whatever it held, so asking the draft is the only way
    // to name the route she is actually about to ride.
    final riding = ref.read(journeyDraftProvider).routeChainIds;
    final ridden = riding == null
        ? options.first
        : options.where((o) => o.isChain(riding)).firstOrNull ?? options.first;
    return ridden.viaLabel;
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
    // "Checking…" for the rest of the ride. earphonesConnected bounds its own
    // session and route read since 11 Sep 2026, and the volume probes bound
    // theirs, so this outer bound is now a belt: it is what holds if any of
    // them grows an await nobody bounded, which is exactly how
    // `AudioSession.instance` hung here before. Falling back to the values
    // already on screen means a timeout reads as "no change", which is the
    // honest answer: we asked and learned nothing.
    //
    // NULL means the probe did not answer, and a probe that did not answer must
    // change NOTHING. Returning "volume unreadable" on a timeout would clear a
    // warning that is still true, which is the one direction this screen must
    // never fail in.
    final client = ref.read(rideServiceClientProvider);
    final probe = await Future.wait([
      widget.audio.earphonesConnected(),
      client.alarmVolume(),
      client.mediaVolume(),
    ]).timeout(const Duration(seconds: 3), onTimeout: () => const []);

    final answered = probe.isNotEmpty;
    final connected = answered ? probe[0] as bool : _earphonesConnected;
    final volume = answered ? probe[1] as double? : null;
    final volumeLow = answered ? _sliderIsLow(volume) : _volumeLow;
    // The media slider is rechecked on the same terms as the alarm slider,
    // because it is the same rider walking to the same platform turning the
    // same phone up. A recheck that cleared one warning and left the other
    // standing on a stale reading would be the screen lying about which of
    // the two it had just asked about.
    final announcementVolume = answered ? probe[2] as double? : null;
    final announcementsSilent = answered
        ? _sliderIsLow(announcementVolume)
        : _announcementsSilent;
    final changed =
        connected != _earphonesConnected ||
        volumeLow != _volumeLow ||
        announcementsSilent != _announcementsSilent;

    // Hold "Checking…" long enough to be seen. Measured from the tap, so a slow
    // probe waits no longer than it already took.
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = PreflightScreen.recheckMinimum - elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    if (!mounted) return;

    setState(() {
      _earphonesConnected = connected;
      _volumeLow = volumeLow;
      _announcementsSilent = announcementsSilent;
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
          if (_announcementsSilent)
            const PrepStep(
              // TWO SLIDERS, TWO SENTENCES, AND THE DIFFERENCE IS THE POINT.
              // The row above is about the alarm and says the rider may not
              // wake. This one must NOT say that: on Android the ladder tone
              // rides STREAM_ALARM and the media slider cannot touch it, so
              // borrowing the stronger words would be the same drift F1 was
              // built to stop, in the same direction, on the same screen.
              // What is genuinely lost is everything the app SAYS: every
              // station announcement, and the spoken line the ladder opens
              // with before it starts sounding tones.
              label: 'You will not hear the station names',
              // Names what survives, so the rider can judge it, and names the
              // slider rather than a number they cannot see on their own
              // phone. The same rule the alarm row follows.
              detail: 'The alarm still sounds. Turn up the media volume',
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
        onStart: () => unawaited(_enterCommitWindow()),
        onRecheck: () => unawaited(_recheckAudio()),
        recheckState: _recheck,
      ),
      _Stage.committing => StartingScreen(
        originName: _originName,
        destinationName: destination,
        viaLabel: _viaLabel,
        remaining: _window,
        onCancel: _cancelCommit,
      ),
    };
  }
}

/// A slider is low enough to be worth stopping a rider over.
///
/// ONE DEFINITION, SHARED BY BOTH SLIDERS, and it is where the threshold
/// argument lives. It was written four times across this file on 8 Sep 2026,
/// twice per slider, which is four places for one number to drift and four
/// places to forget when a bench finally tunes it.
///
/// NULL IS NOT LOW. A platform that will not answer has told us nothing, and
/// nothing is not a warning: on iOS [RideServiceClient.mediaVolume] answers
/// null on every ride, so reading null as low would put a warning in front of
/// every iPhone rider forever.
///
/// THE NUMBER IS THE ALARM'S 0.3, AND IT IS REUSED WITH ITS ARGUMENT ONLY
/// HALF INTACT, which is worth saying plainly rather than implying it
/// transfers. [AudioOutputGateway.lowVolume] was set from two things: that a
/// warning firing before ordinary rides teaches riders to tap past the one
/// that mattered, and that the ladder's first rung at 0.3 of system volume
/// lands near 9 percent of full scale and is inaudible in a carriage. The
/// first half carries over exactly. THE SECOND DOES NOT: announcements have
/// no rung ladder and play at full scale, so 0.3 of the media slider is
/// louder than 0.3 of the alarm slider ever is. It is reused anyway, because
/// a carriage is loud enough that the direction is certainly right and a
/// second number invented at a desk would be a second thing to tune against
/// nothing. Neither number is measured yet; the ride log records both at
/// every start, so a later session can tune them against real rides.
bool _sliderIsLow(double? volume) =>
    volume != null && volume < AudioOutputGateway.lowVolume;

/// What the cheap probes found. Built by [PreparingGate.check].
class PreparingReport {
  const PreparingReport({
    required this.hasFix,
    required this.originName,
    required this.backgroundLocationGranted,
    required this.earphonesConnected,
    this.alarmVolume,
    this.mediaVolume,
  });

  final bool hasFix;
  final String? originName;
  final bool backgroundLocationGranted;
  final bool earphonesConnected;

  /// How loud the wake alarm will be, 0.0 to 1.0, or null when the platform
  /// would not say. Null is NOT a warning: see [AudioOutputGateway.alarmVolume].
  final double? alarmVolume;

  /// How loud everything the app SAYS will be, 0.0 to 1.0, or null where the
  /// platform will not answer. Null is NOT a warning, the same rule as
  /// [alarmVolume], and here it is the ordinary iOS answer rather than a
  /// failure. See [RideServiceClient.mediaVolume].
  final double? mediaVolume;

  /// The rider's volume is low enough that the alarm may not wake them.
  ///
  /// ADDED 11 Aug 2026, and it was specified from the start and never built.
  /// This file's own doc listed "(earphones or volume)" as the two audio
  /// checks, and the debug screen has carried a "Volume is low" chip since
  /// Screen 3 was drawn, wired to nothing, because nothing in the app had ever
  /// read the system volume. So a rider with the volume down started a ride,
  /// saw no warning, and slept through an alarm that played into silence while
  /// every log line reported success.
  bool get volumeLow => _sliderIsLow(alarmVolume);

  /// The rider will hear nothing the app SAYS, and the alarm tone is not what
  /// is at stake.
  ///
  /// ADDED 8 SEP 2026, AND IT IS THE 5 SEP RIDE WRITTEN AS A CHECK. A tester
  /// on a Xiaomi heard no station announcements and no spoken wake while his
  /// own log recorded "Alarm volume at start: 100%". Nothing was broken. Speech
  /// rides the MEDIA stream, the ladder tone rides the alarm stream, and this
  /// screen read only the second one. So the app handed a clean bill of health
  /// to a phone that would not say a word for eighteen stations, and no rider
  /// could tell that from a broken app. `2986dab` put the number in the ride
  /// log, which answers the question AFTER a ride; this is the same number at
  /// the only moment a rider can still act on it.
  ///
  /// ANDROID ONLY, BY CONSTRUCTION AND NOT BY OVERSIGHT. iOS has no alarm
  /// stream, so [alarmVolume] there reads `outputVolume`, which is what the
  /// spoken lines get too: one number already covers both and the existing row
  /// says it. On Android the two sliders are genuinely independent, which is
  /// exactly where the Xiaomi was. [mediaVolume] answers null on iOS and null
  /// warns about nothing.
  ///
  /// The threshold is the alarm's, reused rather than invented, and the half
  /// of its argument that does NOT carry over is written down at
  /// [_sliderIsLow] rather than waved at here.
  bool get announcementsSilent => _sliderIsLow(mediaVolume);

  /// Nothing to show. The ride starts and Screen 3 never appears, which is the
  /// normal case.
  bool get clear =>
      hasFix &&
      backgroundLocationGranted &&
      audioIsClear(
        earphonesConnected: earphonesConnected,
        volumeLow: volumeLow,
        announcementsSilent: announcementsSilent,
      );
}

/// Every audio warning this screen can draw, in ONE expression.
///
/// THE TWO READERS ARE THE POINT. [PreparingReport.clear] decides whether the
/// flow is worth pushing at all, and `_settleIfClear` decides whether a flow
/// already on screen walks itself into the commit window. They are different
/// questions asked at different moments and they must agree, because a warning
/// that only one of them knows about either draws for a single frame and
/// settles past itself, or stops a ride nobody was warned about.
///
/// This was a comment on 8 Sep 2026 telling the next reader to remember to
/// edit both. A comment cannot fail a build. Taking the parameters by name
/// means adding a warning here breaks every caller that has not been given the
/// new evidence, which is the same trick the wake engine's `_Claim` used to
/// stop one of its two counters being updated and the other forgotten.
bool audioIsClear({
  required bool earphonesConnected,
  required bool volumeLow,
  required bool announcementsSilent,
}) => earphonesConnected && !volumeLow && !announcementsSilent;

/// Where the ride-start path asks about earphones. A provider for the same
/// reason `permissionsGatewayProvider` is one: `AudioSession.instance` does not
/// answer under the widget-test binding, so without this seam no test could
/// drive a tap on Screen 1 into a ride.
final audioOutputGatewayProvider = Provider<AudioOutputGateway>(
  (ref) => const AudioOutputGateway(),
);

/// The commit window's voice, on the ride-start path. Null in production, where
/// the window builds its own engine exactly as it always has.
final commitAnnouncerProvider = Provider<CommitAnnouncer?>((ref) => null);

/// Runs the probes that decide whether Screen 3 is needed at all.
class PreparingGate {
  const PreparingGate({
    this.permissions = const PermissionsGateway(),
    this.audio = const AudioOutputGateway(),
  });

  final PermissionsGateway permissions;
  final AudioOutputGateway audio;

  /// How long any one probe may take before its answer is assumed.
  ///
  /// The same two seconds the volume probes and `getDevices` already carry
  /// inside themselves, so a probe that was answering in time before still is.
  static const probeBudget = Duration(seconds: 2);

  /// NOTHING HERE MAY THROW OR HANG, because the caller cannot say so. The
  /// only caller is `prepareAndStart`, fired UNAWAITED from every card on
  /// Screen 1 and from Screen 2's picker, so a throw or a hang in here was a
  /// tap that did nothing: no ride, no screen, no log. Measured on 11 Sep 2026
  /// by `prepare_and_start_test.dart`, which could not reach a ride through a
  /// permission read that threw or an earphone probe that never answered.
  ///
  /// Two holes, both real. `hasAlways` had no catch at all. And
  /// `earphonesConnected` bounded `getDevices` but not the
  /// `AudioSession.instance` await in front of it, which is the await that
  /// hangs under the test binding. That one is now also fixed at the source,
  /// in the gateway, because `startRide` reads the same probe after the
  /// window; the bound here stays, so a probe that grows a new unbounded await
  /// still cannot eat the tap.
  ///
  /// A PROBE THAT FAILS ANSWERS THE WAY THE PROBES ALREADY FAIL: OPEN. No
  /// warning is drawn for a problem nobody could confirm, because a false
  /// warning before every ride teaches a rider to tap past the screen that
  /// matters. Permission counts too: `start()` asks for it again regardless,
  /// and the service logs what it was actually given.
  ///
  /// ALL FOUR AT ONCE, NOT ONE AFTER ANOTHER. They have nothing to say to each
  /// other, and in sequence a slow phone paid each budget in turn. The volumes
  /// were put in one wait on 8 Sep 2026; the other two now join them, so the
  /// worst case is one budget, not four.
  Future<PreparingReport> check(WidgetRef ref) async {
    final fix = ref.read(nearestStationProvider);
    final hasFix = fix.state == GpsState.located;
    final client = ref.read(rideServiceClientProvider);
    final (granted, earphones, alarmVolume, mediaVolume) = await (
      _answer(permissions.hasAlways, whenUnknown: true),
      _answer(audio.earphonesConnected, whenUnknown: true),
      _answer(client.alarmVolume, whenUnknown: null),
      _answer(client.mediaVolume, whenUnknown: null),
    ).wait;
    return PreparingReport(
      hasFix: hasFix,
      originName: hasFix ? fix.stationName : null,
      backgroundLocationGranted: granted,
      earphonesConnected: earphones,
      alarmVolume: alarmVolume,
      mediaVolume: mediaVolume,
    );
  }

  /// One probe, bounded, with its unknown answer named at the call site.
  ///
  /// Takes the probe as a FUNCTION rather than a future, so a gateway that
  /// throws before it has returned a future is caught here too and not in
  /// the unawaited caller.
  static Future<T> _answer<T>(
    Future<T> Function() probe, {
    required T whenUnknown,
  }) async {
    try {
      return await probe().timeout(probeBudget, onTimeout: () => whenUnknown);
    } catch (_) {
      return whenUnknown;
    }
  }
}
