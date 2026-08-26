import AVFoundation
import AudioToolbox
import CallKit
import CoreLocation
import Flutter
import MediaPlayer
import UIKit
import UserNotifications
import flutter_foreground_task

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Wake escalation earphone-tap acknowledgment (W1 spike). While a ladder
  /// is live, every remote command (AirPods tap, inline click, lock-screen
  /// control) means "I'm awake" and is forwarded to Dart.
  ///
  /// Routing requires this app to be the Now Playing owner, and the 15 Jul
  /// iPhone bench proved registering command handlers is not enough: with
  /// the rider's music app playing (even ducked), iOS kept routing taps to
  /// it, and a TWS tap just skipped the song. Ownership goes to the app
  /// playing PRIMARY (non-mixing) audio, so while a ladder is live this
  /// seizes the session exclusively (the music pauses, and resumes on
  /// stand-down via notifyOthersOnDeactivation), plays a silent looping
  /// keepalive so the system sees real playback even during the silent
  /// check-in window (the iOS twin of the Android muted-AudioTrack claim),
  /// and posts a Now Playing card so lock-screen controls ack too.
  private var mediaAckChannel: FlutterMethodChannel?
  private var ackTargets: [(MPRemoteCommand, Any)] = []
  private var keepAliveEngine: AVAudioEngine?

  /// The hidden volume control. See [raiseAlarmVolume]. Held so the view stays
  /// in the hierarchy: a slider on a deallocated MPVolumeView moves nothing.
  private var volumeView: MPVolumeView?
  private var volumeSlider: UISlider?

  /// The ladder tone, played natively. audioplayers' ReleaseMode.loop never
  /// actually looped under the seized session (IPA #18, all four runs: the
  /// 5 s wav died each cycle and the Dart watchdog restarted it with an
  /// audible gap, and the silent moments are the lead suspect for the 18 Jul
  /// lost earphone ack). AVAudioPlayer with numberOfLoops = -1 loops in the
  /// session this class already owns.
  private var tonePlayer: AVAudioPlayer?
  private var toneAssetPath: String?

  /// Call detection, independent of the audio session (locked decision 8: on
  /// a call means awake).
  ///
  /// The 23 Jul bench is why this exists. Travel Mode ran, the phone sat
  /// silent, a real call was answered, and the app logged NOTHING at all: not
  /// an interruption, not a withheld one. iOS delivers AVAudioSession
  /// interruptions for a session it considers ACTIVE, and 45279c1
  /// deliberately releases ours between announcements so the rider's music is
  /// never left ducked. So the only calls we could ever see were the ones that
  /// happened to arrive while we were making noise, which is every
  /// interruption we have ever observed on iOS and none of the ones we cared
  /// about most. CXCallObserver reports calls regardless of who owns audio.
  ///
  /// Do NOT "fix" the original gap by holding the session active for the whole
  /// ride. That re-breaks the bench-verified ducking 45279c1 existed to get
  /// right, and this costs nothing by comparison.
  private var callObserver: CXCallObserver?

  /// Calls currently proving the rider is awake, by UUID. A set rather than a
  /// bool because call waiting, conference calls and a second incoming call
  /// all overlap: the rider stops being on a call when the LAST one ends, not
  /// when the first does.
  private var engagedCalls: Set<UUID> = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required so plugins (TTS, location) are registered on the engine that
    // flutter_foreground_task spawns for the background TaskHandler on iOS.
    // NO CAPTURES IN HERE. This takes a C FUNCTION POINTER, so a closure that
    // captures anything, `self` included, fails to compile with "a C function
    // pointer cannot be formed from a closure that captures context". That is
    // why the thermal channel is registered by a file-scope function rather
    // than by a method on this class. Found by CI on 18 Aug 2026, because Swift
    // does not compile on the machine this was written on.
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      // The ride runs in THIS engine, so the thermal channel has to exist here
      // as well as on the implicit one. See registerThermalChannel.
      registerThermalChannel(with: registry)
      // Same reason: the SERVICE is what arms and disarms the lifeline, because
      // the service owns both edges of a ride. See registerRelaunchChannel.
      registerRelaunchChannel(with: registry)
    }
    // BEFORE super, and before any Dart runs. This is the only moment the
    // launch options are on offer, and the answer they carry ("iOS started this
    // process because the phone moved") is the entire premise of the lifeline.
    relaunchLifeline.noteLaunch(options: launchOptions)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerThermalChannel(with: engineBridge.pluginRegistry)
    // THE ENGINE THAT ANSWERS THE RELAUNCH. A killed ride has no service
    // isolate left, so the process iOS wakes has only this one, and the whole
    // decision is taken here.
    registerRelaunchChannel(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "media_ack") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "commute_guardian/media_ack",
      binaryMessenger: registrar.messenger()
    )
    let toneKey = registrar.lookupKey(forAsset: "assets/audio/wake_alarm.wav")
    toneAssetPath = Bundle.main.path(forResource: toneKey, ofType: nil)

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      // The audio notes these two return travel back to Dart and into the ride
      // log. That file is the only instrument a sideloaded iPhone gives us, and
      // until 24 Jul a refused seizure was invisible in it: the log looked
      // identical whether the alarm was sounding or silent.
      case "startSession":
        result(self?.startAckSession() ?? nil)
      case "stopSession":
        self?.stopAckSession()
        result(nil)
      case "startTone":
        let volume = (call.arguments as? NSNumber)?.floatValue ?? 1.0
        result(self?.startTone(volume: volume) ?? nil)
      case "stopTone":
        self?.stopTone()
        result(nil)
      case "getAlarmVolume":
        result(self?.alarmVolume())
      case "raiseAlarmVolume":
        let floor = (call.arguments as? NSNumber)?.floatValue ?? 0.7
        // ASYNC, because the decision now needs more than one reading. See
        // raiseAlarmVolume. Dart already allows two seconds for this call.
        self?.raiseAlarmVolume(to: floor) { result($0) }
      case "restoreAlarmVolume":
        let previous = (call.arguments as? NSNumber)?.floatValue ?? -1
        result(self?.restoreAlarmVolume(to: previous))
      case "vibrate":
        // THE BENCH, 11 Aug 2026. CLAUDE.md locked "haptics are Android-only"
        // on the correct premise that iOS forbids BACKGROUND haptics, and both
        // haptics APIs confirm it: CHHapticEngine stops when the app leaves the
        // foreground, and UIFeedbackGenerator is foreground-only by design.
        // There is no entitlement to ask Apple for.
        //
        // kSystemSoundID_Vibrate is the one public call that has ever been
        // REPORTED to fire from a backgrounded app, and the reports are
        // version-dependent enough that reasoning about it is worthless. This
        // exists so the owner's phone can answer instead. It is the oldest
        // vibration API on the platform, predating the Taptic Engine, and it
        // ignores the intensity controls the newer ones respect.
        //
        // If the bench says no, delete this and the locked decision stands.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    mediaAckChannel = channel

    // Observed for the whole life of the app, not just while a ladder is
    // live: the point of this signal is the call that arrives when we are
    // making no sound at all, and the Dart side ignores it when no ride is
    // running. Registering once here also means there is no start/stop pair
    // to leave dangling.
    let observer = CXCallObserver()
    observer.setDelegate(self, queue: .main)
    // Seed from the calls already in progress. callChanged fires on
    // TRANSITIONS only, so a call that was already connected when the observer
    // registered would otherwise never be reported, and the rider would be
    // escalated at mid-conversation.
    for call in observer.calls where !call.hasEnded
      && (call.hasConnected || call.isOutgoing)
    {
      engagedCalls.insert(call.uuid)
    }
    callObserver = observer
  }

  /// Starts the looping tone, or just moves its volume when it is already
  /// playing. Also the self-heal: Dart re-sends startTone on every service
  /// tick while a ladder is live, so a player an interruption killed comes
  /// back within a tick.
  ///
  /// Returns a note for the ride log when it actually (re)started the tone,
  /// naming which session mode took, and nil when there was nothing to do. A
  /// volume change on a healthy player is silent in the log on purpose: this
  /// fires every ~5 s tick and would otherwise bury the ride.
  /// How loud the wake alarm will actually be, 0.0 to 1.0, or nil when iOS
  /// will not say.
  ///
  /// iOS HAS NO SEPARATE ALARM STREAM. Android's tone rides STREAM_ALARM and is
  /// immune to the media slider; here the ladder plays on the playback
  /// category, so `outputVolume` IS the volume the alarm gets. That asymmetry
  /// is why this returns one number and the Dart side does not try to reconcile
  /// the two platforms.
  ///
  /// The Ring/Silent switch is a different control again and is NOT readable
  /// through any public API. Playback ignores it, which is why the ladder is
  /// built on that category, so a low reading here is the failure worth
  /// warning about and the switch is not.
  ///
  /// THE SESSION HAS TO BE ACTIVE OR THE NUMBER IS STALE, corrected 11 Aug 2026
  /// the same evening this was written. `outputVolume` is only documented as
  /// valid on an ACTIVE session; on an inactive one it returns whatever was last
  /// true, which on Screen 3 means the pre-flight check answers a question about
  /// the past. The rider then turns their volume up, presses "check again", and
  /// is told nothing changed. That is the bug they reported.
  ///
  /// AMBIENT plus MIX-WITH-OTHERS, chosen so activating cannot cost anything.
  /// Ambient never interrupts, so a rider listening to music keeps listening.
  /// Activating the DEFAULT category (soloAmbient) would have stopped their
  /// audio to measure a volume, before a ride had even started, which is a
  /// worse thing than the warning is worth.
  ///
  /// Not deactivated afterwards, deliberately. Deactivating can notify other
  /// apps that they may resume, which is a side effect this has no business
  /// causing, and the ride's own `seizeSession` overrides the category anyway.
  private func alarmVolume() -> NSNumber? {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      // Fall through and read anyway: a stale number beats no number, and the
      // Dart side treats an implausible one as "would not say".
      NSLog("AlarmVolume: could not activate to measure: \(error)")
    }
    let volume = session.outputVolume
    guard volume.isFinite, volume >= 0 else { return nil }
    return NSNumber(value: volume)
  }

  /// THE MEDIA SLIDER IS THE ALARM'S VOLUME ON THIS PLATFORM, so an alarm that
  /// respects a slider at zero is an alarm that cannot wake anybody.
  ///
  /// Owner decision, 13 Aug 2026, after the Bench B Part 2 log opened with
  /// "Alarm volume at start: 0%" and the whole ladder ran its course in
  /// silence. It is the third time his phone has done this. Android needs none
  /// of it: the tone rides STREAM_ALARM and the media slider cannot touch it.
  ///
  /// WHAT THIS IS: MPVolumeView's embedded UISlider, which is the only way an
  /// app can move system volume. MPVolumeView is public API and the view is
  /// never shown; what is not contractual is that its first UISlider subview is
  /// the volume control, so this fails SOFTLY and says so rather than throwing.
  ///
  /// IT ONLY EVER RAISES, and only to [floor]. A rider who has deliberately set
  /// 90 percent keeps 90. Lowering someone's volume would be a worse fault than
  /// the one this fixes.
  ///
  /// THE RISK WORTH KNOWING: this drives a UIKit control, and the ride runs in
  /// a headless engine with the phone locked in a pocket, which is exactly when
  /// it matters. Whether UIKit will move a slider for a backgrounded app is not
  /// something the documentation answers. That is why every step returns a note
  /// into the ride log: the next bench reads the log and says.
  /// RETURNS THE VOLUME IT ACTUALLY TOOK, and only when it took one.
  ///
  /// THE 14 AUG 2026 BENCH IS WHY THIS RETURNS A MAP INSTEAD OF A NOTE. Dart
  /// used to take its OWN reading of `outputVolume` to decide what to remember,
  /// while this method took a second one to decide what to do. The two
  /// disagreed, in both directions across two logs of the same evening:
  ///
  ///   18:36  "Alarm volume at start: 85%"  ->  here: "raised from 65% to 70%"
  ///   18:42  "Alarm volume at start: 65%"  ->  here: "85% already at or above"
  ///
  /// `outputVolume` is only trustworthy on an ACTIVE session, and Dart's read
  /// happened before the ladder seized one. So the rider's phone was restored
  /// to a number nobody had measured: at 18:46 it was dropped from 85 to 65,
  /// having never been raised at all. Lowering a rider's alarm volume is the
  /// exact fault this whole feature exists to prevent.
  ///
  /// ONE READ NOW, taken here, after the session is active. `raisedFrom` is
  /// absent unless the slider really moved, and absent is what Dart turns into
  /// "leave them alone".
  /// How many readings of `outputVolume` are taken before acting, and how far
  /// apart. See [raiseAlarmVolume] for what one reading cost.
  private static let volumeSamples = 4
  private static let volumeSampleGap = 0.08

  /// Samples `outputVolume` [volumeSamples] times and hands back every reading.
  ///
  /// ONE READING IS NOT ENOUGH, learned the hard way on 14 Aug 2026. See
  /// [raiseAlarmVolume].
  private func sampleOutputVolume(
    _ done: @escaping ([Float]) -> Void, collected: [Float] = []
  ) {
    let session = AVAudioSession.sharedInstance()
    var samples = collected
    samples.append(session.outputVolume)
    if samples.count >= AppDelegate.volumeSamples {
      done(samples)
      return
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AppDelegate.volumeSampleGap
    ) { [weak self] in
      self?.sampleOutputVolume(done, collected: samples)
    }
  }

  /// Raises the media volume to [floor] for an alarm, and NEVER LOWERS IT.
  ///
  /// THE 14 AUG 2026 BENCH BROKE THE ONLY PROMISE THIS MAKES. The rider's
  /// slider was at 90 percent with earphones connected. The ladder read 65,
  /// set the slider to 70, and afterwards restored it to 65. A feature whose
  /// entire purpose is to guarantee the alarm can be heard made the phone
  /// quieter, twice.
  ///
  /// THE SAMPLING BELOW DID NOT FIX IT, and this comment is the correction.
  ///
  /// It was built on the theory that the reading was STALE because it lands one
  /// millisecond after `setActive(true)`. The bench that followed took four
  /// samples 80 ms apart and got `65%, 65%, 65%, 65%` while the rider's slider
  /// was at 90 and he confirmed it by eye. Stable, and still wrong. Timing is
  /// not the variable.
  ///
  /// WHAT THE VARIABLE LOOKS LIKE, and it is a HYPOTHESIS awaiting one bench:
  /// the CATEGORY. The reading that has been right every time comes from
  /// `alarmVolume()`, which activates `.ambient` with `mixWithOthers`. This one
  /// runs after `seizeSession()` has taken `.playback` with NO options, which
  /// is EXCLUSIVE. Taking an exclusive session appears to change which route's
  /// volume iOS reports.
  ///
  /// THE SAMPLING IS KEPT because it costs 240 ms and it is the instrument that
  /// proved timing innocent. Every sample goes into the ride log, so the next
  /// bench can read them rather than argue about them.
  ///
  /// THE FEATURE STILL LOWERS A LOUD RIDER'S VOLUME. Taking the maximum of four
  /// wrong readings is still a wrong reading. The owner was shown this and
  /// chose to leave it for now; the design question (fail quiet, or fail loud)
  /// is open and is the first thing to settle before touching this again.
  private func raiseAlarmVolume(
    to floor: Float, done: @escaping ([String: Any]) -> Void
  ) {
    sampleOutputVolume { [weak self] samples in
      let usable = samples.filter { $0.isFinite && $0 >= 0 }
      let readings = samples
        .map { String(format: "%.0f%%", $0 * 100) }
        .joined(separator: ", ")
      guard let highest = usable.max() else {
        done(["note": "ALARM VOLUME: could not read (\(readings)), left alone."])
        return
      }
      if highest >= floor {
        done(["note": String(
          format: "ALARM VOLUME: %.0f%% already at or above the %.0f%% floor "
            + "(read %@).",
          highest * 100, floor * 100, readings)])
        return
      }
      guard let slider = self?.systemVolumeSlider() else {
        done(["note": String(
          format: "ALARM VOLUME: %.0f%%, BUT NO SYSTEM SLIDER, left alone.",
          highest * 100)])
        return
      }
      DispatchQueue.main.async { slider.value = floor }
      done([
        "note": String(
          format: "ALARM VOLUME: raised from %.0f%% to %.0f%% for the alarm "
            + "(read %@).",
          highest * 100, floor * 100, readings),
        "raisedFrom": Double(highest),
      ])
    }
  }

  /// Puts the rider's own volume back. A negative [previous] means the ladder
  /// never raised it, so nothing is touched: restoring a number we did not take
  /// would be its own way of changing someone's volume behind their back.
  private func restoreAlarmVolume(to previous: Float) -> String? {
    guard previous >= 0 else { return nil }
    guard let slider = systemVolumeSlider() else {
      return "ALARM VOLUME: no system slider, could not restore."
    }
    DispatchQueue.main.async { slider.value = previous }
    return String(
      format: "ALARM VOLUME: restored to %.0f%%.", previous * 100)
  }

  /// The hidden MPVolumeView's slider, built once and kept in the window so
  /// iOS treats it as a real control. Never visible: zero size and clear.
  private func systemVolumeSlider() -> UISlider? {
    if let existing = volumeSlider { return existing }
    let view = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    view.isHidden = false
    view.alpha = 0.001
    if let window = UIApplication.shared.windows.first {
      window.addSubview(view)
    }
    volumeView = view
    volumeSlider = view.subviews.compactMap { $0 as? UISlider }.first
    return volumeSlider
  }

  private func startTone(volume: Float) -> String? {
    // Re-assert Now Playing ownership on every tick. flutter_tts activates the
    // shared session for each utterance (check-in, each rung), which can hand
    // remote-command routing back to whatever spoke last, so a double-tap
    // mid-ladder finds no target. This was the 20 Jul regression: the tone
    // loop (096d96c) was fine, but the earphone ack silently stopped working
    // and the rider had to open the app. Dart resends startTone every ~5 s, so
    // reclaiming here keeps us the target between utterances. Cheap and safe:
    // re-posting the card does not touch the session or the tone.
    refreshNowPlaying()
    if let player = tonePlayer, player.isPlaying {
      player.volume = volume
      return nil
    }
    guard let path = toneAssetPath else {
      NSLog("WakeTone: wake_alarm.wav not found in the bundle")
      return "tone asset missing from the bundle"
    }
    // The player is not playing, so either it never started or something took
    // the session out from under us and iOS stopped it. Re-seize BEFORE
    // playing: an interruption deactivates our session, and calling play() on
    // a dead session produces a player that reports success and makes no
    // sound.
    //
    // The 23 Jul bench is why this exists. Mid-ladder the rider opened Music
    // and pressed play. iOS interrupted us, our tone stopped, and nothing ever
    // took the session back, so the ladder went on logging rungs 0.6 and 1.0
    // into total silence. Six test announcements, the stand-down line and the
    // farewell were all inaudible too. Remote commands kept working (the card
    // is re-posted above), so the rider could still ack; they just could not
    // hear anything. A wake alarm that reports success while making no sound
    // is the worst failure this app has.
    //
    // Deliberately NOT done on the healthy path above: changing the category
    // of a live session can cut off audio that is already playing, including
    // our own TTS. Only the recovery path needs it.
    let seized = seizeSession()
    do {
      let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      player.numberOfLoops = -1
      player.volume = volume
      player.play()
      tonePlayer = player
      return "tone (re)started, session \(seized)"
    } catch {
      NSLog("WakeTone: could not start the tone: \(error)")
      return "tone failed to start (session \(seized)): \(describeAudioError(error))"
    }
  }

  private func stopTone() {
    tonePlayer?.stop()
    tonePlayer = nil
  }

  /// Takes the audio session for the alarm, exclusively if iOS allows it and
  /// mixed over the rider's audio if it does not. Returns what happened, for
  /// the ride log.
  ///
  /// Exclusive (non-mixing) playback is what earns remote-command routing:
  /// iOS gives Now Playing to the app playing PRIMARY audio, so a mixing
  /// session can never own the earphone tap. The rider's music is interrupted
  /// (paused) as a consequence, and stand-down hands it back.
  ///
  /// BUT IT IS NOT ALWAYS OURS TO TAKE, and the 24 Jul bench is why this
  /// escalates. A BACKGROUNDED app may not activate a NON-MIXABLE session
  /// while another app is playing audio: iOS refuses with CannotInterruptOthers.
  /// Mid-ladder the rider started Music with the phone in his hand, then stayed
  /// in Music, and every re-seize was refused for 1 minute 57 seconds while the
  /// ladder logged SEVEN rungs at full volume into total silence. It recovered
  /// the instant the app came to the foreground, which is the tell. On a real
  /// ride nobody foregrounds anything, because the rider is asleep, which is
  /// the whole point of the alarm.
  ///
  /// So exclusivity is now best-effort and AUDIBILITY WINS. A ducking session
  /// is mixable, which iOS does permit from the background, so the alarm sounds
  /// OVER the rider's music instead of not at all. The cost is the earphone
  /// tap: mixing forfeits Now Playing, so in that state the ack is the on-screen
  /// button. A silent alarm is worth nothing; a loud one with a worse ack still
  /// wakes the rider.
  ///
  /// Idempotent, which is what lets the tone watchdog call it on the recovery
  /// path without having to know whether anything was actually lost: setting
  /// the category and activating a session we already hold are both no-ops.
  private func seizeSession() -> String {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
      return "exclusive"
    } catch {
      let refusal = describeAudioError(error)
      do {
        // The same profile the announcement path uses, so this is a mode the
        // app is already proven to be able to hold.
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.mixWithOthers, .duckOthers]
        )
        try session.setActive(true)
        return "ducked (exclusive refused: \(refusal))"
      } catch {
        // Nothing sounds. The one case where the alarm is genuinely lost, and
        // now it says so in the ride log instead of only in NSLog, which a
        // sideloaded build cannot show.
        return "NONE (exclusive refused: \(refusal), "
          + "ducked refused: \(describeAudioError(error)))"
      }
    }
  }

  /// Names the refusal codes this app can actually hit, because the number
  /// alone sends the next reader to a search engine mid-diagnosis.
  private func describeAudioError(_ error: Error) -> String {
    let code = (error as NSError).code
    switch code {
    case 560557684:
      // AVAudioSessionErrorCodeCannotInterruptOthers. Backgrounded, and
      // something else is playing. The 24 Jul suspect.
      return "CannotInterruptOthers (\(code))"
    case 561015905:
      // AVAudioSessionErrorCodeCannotStartPlaying.
      return "CannotStartPlaying (\(code))"
    default:
      return "code \(code)"
    }
  }

  /// Returns which session mode the ladder started under, for the ride log.
  /// This is the one that decides whether the EARPHONE ack can work at all:
  /// exclusive means we are the Now Playing owner and the tap reaches us,
  /// ducked means the rider's music still owns the buttons and the tap will
  /// skip a track, exactly as it did on the 22 Jul ride.
  private func startAckSession() -> String? {
    guard ackTargets.isEmpty else { return nil }

    let seized = seizeSession()

    startKeepAlive()

    let center = MPRemoteCommandCenter.shared()
    // Every remote command means "I'm awake". The name is forwarded so the
    // ack log records which gesture actually reached us (a double-tap maps to
    // different commands across earbuds); if none appears on a real tap, the
    // tap never routed to us and the fix above did not hold.
    let named: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"),
      (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "togglePlayPause"),
      (center.nextTrackCommand, "next"),
      (center.previousTrackCommand, "previous"),
    ]
    for (command, name) in named {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.mediaAckChannel?.invokeMethod("ack", arguments: name)
        return .success
      }
      ackTargets.append((command, target))
    }

    // Posted after the commands are registered, so the card and the routing
    // target come up together.
    refreshNowPlaying()

    return "ladder session \(seized)"
  }

  /// Posts (or re-posts) the Now Playing card that marks this app as the
  /// active remote-command target. A no-op unless a ladder's ack session is
  /// live (its commands are registered).
  private func refreshNowPlaying() {
    guard !ackTargets.isEmpty else { return }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = [
      MPMediaItemPropertyTitle: "Commute Guardian wake alert",
      MPNowPlayingInfoPropertyPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
      MPMediaItemPropertyPlaybackDuration: 0.0,
      MPNowPlayingInfoPropertyIsLiveStream: true,
    ]
    // The 21 Jul bench proved the rider's double-tap DOES emit a media command
    // (it skips tracks in his music app) and that it never reaches us. Posting
    // the card and enabling the commands is not enough: since iOS 13 an app
    // that does not drive MPMusicPlayerController must declare playbackState
    // explicitly to be treated as the Now Playing app, and only the Now Playing
    // app receives an accessory's command. Without this the tap goes to
    // whichever app does claim it, which is what the rider observed. This also
    // explains the regression between IPA #17 and #20 with no change to the ack
    // code: 096d96c moved the tone into this class and changed who the system
    // saw playing.
    center.playbackState = .playing
  }

  private func stopAckSession() {
    // Defensive: the ladder's stand-down sends stopTone first, but the
    // session must never be released with the tone still attached to it.
    stopTone()

    for (command, target) in ackTargets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    ackTargets = []

    stopKeepAlive()
    // Stand down as the Now Playing app before dropping the card, so the
    // rider's music app is free to reclaim the accessory's buttons.
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

    // notifyOthersOnDeactivation is what invites the rider's music back.
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    } catch {
      NSLog("WakeAck: could not release the audio session: \(error)")
    }
  }

  /// A looping silent buffer. It costs nothing audible, but it makes this
  /// app's playback REAL to the system for the whole life of the ladder,
  /// including the deliberately silent check-in window before rung 1.
  private func startKeepAlive() {
    guard keepAliveEngine == nil else { return }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
    else {
      NSLog("WakeAck: could not allocate the keepalive buffer")
      return
    }
    buffer.frameLength = buffer.frameCapacity
    if let channels = buffer.floatChannelData {
      for channel in 0..<Int(format.channelCount) {
        memset(
          channels[channel], 0,
          Int(buffer.frameLength) * MemoryLayout<Float>.size)
      }
    }
    do {
      try engine.start()
    } catch {
      NSLog("WakeAck: could not start the keepalive engine: \(error)")
      return
    }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    keepAliveEngine = engine
  }

  private func stopKeepAlive() {
    keepAliveEngine?.stop()
    keepAliveEngine = nil
  }



  // MARK: - State preservation, deliberately OFF

  /// iOS ASKED US TO ARCHIVE STATE AND IT COST A RIDE. 16 Aug 2026, 20:23:43,
  /// on the way back from CSMT: iOS killed Travel Mode with 0x8BADF00D, a
  /// "scene-update watchdog transgression", for exhausting a ten second wall
  /// clock allowance while going into the background. The report names the
  /// exact work:
  ///
  ///   -[UIApplication _applicationDidEnterBackground]
  ///     -[UIApplication _saveApplicationPreservationStateIfSupported]
  ///       -[UIApplication _saveApplicationPreservationState:viewController:...]
  ///         _encodeObject
  ///           -[_UIStateRestorationKeyedArchiverDelegate archiver:willEncodeObject:]
  ///
  /// The ride simply stopped. No announcement was ever spoken again, nothing
  /// was written to History, and the phone in the rider's pocket looked exactly
  /// like a phone doing its job. That is the failure the resume offer exists to
  /// make visible; this is the attempt to stop causing it.
  ///
  /// WE ARCHIVE STATE WE NEVER READ. FlutterAppDelegate answers YES to both
  /// save questions unconditionally, without asking whether the app uses
  /// restoration (engine source, FlutterAppDelegate.mm, "State Restoration").
  /// This app uses none: no `restorationScopeId`, no `RestorationMixin`, and
  /// nothing anywhere in lib/ reads restoration data back. So every trip to the
  /// background paid for an archive that no launch has ever opened.
  ///
  /// WHAT THIS DOES NOT FIX, said plainly. The same report shows Thermal Level
  /// 7, state "serious", the system at 67% CPU and THIS APP at 0.084 seconds,
  /// 0%. We were not spinning, we were blocked on a phone that was already hot
  /// and slow. Deleting this archive removes a real cost we were paying for
  /// nothing. It cannot promise the main thread will never stall again.
  ///
  /// The secure variants are the ones iOS 13 and later actually call; the older
  /// pair is overridden too so a future deployment target change cannot quietly
  /// switch the behaviour back on.
  override func application(
    _ application: UIApplication,
    shouldSaveSecureApplicationState coder: NSCoder
  ) -> Bool {
    false
  }

  override func application(
    _ application: UIApplication,
    shouldRestoreSecureApplicationState coder: NSCoder
  ) -> Bool {
    false
  }

  override func application(
    _ application: UIApplication,
    shouldSaveApplicationState coder: NSCoder
  ) -> Bool {
    false
  }

  override func application(
    _ application: UIApplication,
    shouldRestoreApplicationState coder: NSCoder
  ) -> Bool {
    false
  }
}

extension AppDelegate: CXCallObserverDelegate {
  /// A call changed state. Reports the rider's aggregate call status to Dart
  /// on the EDGES only, so a conference call's churn does not spam the engine.
  ///
  /// WHAT COUNTS AS "AWAKE", and this is the one judgement in here: a call is
  /// counted once it has CONNECTED, or as soon as it is dialled if it is
  /// outgoing (nobody dials in their sleep). A phone merely RINGING is
  /// deliberately not counted. Decision 8 suspends the wake ladder for a rider
  /// who is provably awake, and an unanswered ring proves the opposite if it
  /// proves anything: it is exactly the sleeping rider we exist for, and
  /// silencing their alarm because someone called them would be the worst
  /// failure this app has. Erring here costs politeness in one direction and
  /// the rider's stop in the other.
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    let engaged = !call.hasEnded && (call.hasConnected || call.isOutgoing)
    let wasOnCall = !engagedCalls.isEmpty
    if engaged {
      engagedCalls.insert(call.uuid)
    } else {
      engagedCalls.remove(call.uuid)
    }
    let isOnCall = !engagedCalls.isEmpty
    guard isOnCall != wasOnCall else { return }
    mediaAckChannel?.invokeMethod("callState", arguments: isOnCall)
  }
}

// MARK: - Thermal state, the instrument the 16 Aug kill needed

/// Registers `commute_guardian/thermal` on [registry]'s engine.
///
/// REGISTERED ON BOTH ENGINES, and that is the whole reason this is a
/// separate channel instead of another case in the media ack one. The media
/// ack channel lives on the implicit engine only, which is why the alarm
/// volume is read at Start and carried across the store: the service isolate
/// cannot reach it. A thermal reading taken once at Start would be worth
/// almost nothing. The number we need is how hot the phone gets over ninety
/// minutes, and only the isolate running the ride is there to ask.
///
/// WHY IT MATTERS AT ALL. The 16 Aug 2026 crash report shows Thermal Level 7,
/// state "serious", the system at 67% CPU and this app at 0.084 s, 0%. We
/// were blocked on a phone that was already slow, and that is how a ten
/// second watchdog deadline became reachable. That is the ONLY thermal
/// reading this project has ever had, taken at the moment of death, with
/// nothing to compare it against.
///
/// Costs nothing to read: `thermalState` is a cached property, not a sensor
/// poll.
///
/// FILE SCOPE, NOT A METHOD, and that is forced rather than chosen.
/// `setPluginRegistrantCallback` takes a C FUNCTION POINTER, so the closure
/// that calls this may capture nothing at all, `self` included. Written as a
/// method first, and CI answered with "a C function pointer cannot be formed
/// from a closure that captures context" six minutes later. Swift does not
/// compile on the machine this project is written on, so that round trip costs
/// a macOS runner every time: `ios_state_preservation_test.dart` now guards it
/// at the desk instead.
private func registerThermalChannel(with registry: FlutterPluginRegistry) {
  guard let registrar = registry.registrar(forPlugin: "thermal") else { return }
  let channel = FlutterMethodChannel(
    name: "commute_guardian/thermal",
    binaryMessenger: registrar.messenger()
  )
  channel.setMethodCallHandler { call, result in
    guard call.method == "getThermalState" else {
      result(FlutterMethodNotImplemented)
      return
    }
    // The raw value, not a word, because the enum is ordered and the ride log
    // wants to be able to say "it climbed". Dart names it.
    result(ProcessInfo.processInfo.thermalState.rawValue)
  }
}

// MARK: - The relaunch lifeline, so a killed ride can come back by itself

/// The one instance. FILE SCOPE FOR THE SAME REASON THE THERMAL CHANNEL IS:
/// `setPluginRegistrantCallback` takes a C function pointer, so the closure
/// that registers channels on the service engine may capture nothing at all,
/// `self` included. A global `let` is initialised lazily and exactly once, and
/// every path here reaches it from the main thread.
private let relaunchLifeline = RelaunchLifeline()

/// Asks iOS to start this app again after it has been killed mid-ride.
///
/// WHY THIS EXISTS. `geofencing_api`'s iOS side is a 20-line stub, so this app
/// registers NO OS-level region on either platform: the fences are a Dart
/// engine over the location stream. The consequence was stated plainly when the
/// resume offer was built and it has been true ever since: **iOS never
/// relaunches us after a kill**, so resume-on-reopen helps a rider who opens
/// the app and nobody else. A rider asleep with the phone in their pocket, who
/// is the entire reason this product exists, got silence. On 16 Aug 2026 that
/// is exactly what happened, and the ride simply vanished.
///
/// Significant location change monitoring is the one service iOS offers that
/// SURVIVES TERMINATION. The system holds the registration itself and starts
/// the app again, into the background, when the phone has moved far enough.
/// It costs no extra hardware: the fixes are cell and wifi positioning that the
/// phone is already doing.
///
/// WHAT THIS CLASS IS ALLOWED TO DECIDE: nothing. It arms, it disarms, it
/// reports the fix that woke us, and it posts a notification Dart wrote. Every
/// judgement (is there an interrupted ride, is this fix on the corridor, may we
/// resume without asking) lives in `ride_resume.dart`, where it is pure, tested
/// at the desk, and reproducible without a phone. Swift does not compile on the
/// machine this project is written on, so that rule is not stylistic: a
/// decision put here costs a macOS runner every time it is wrong.
private final class RelaunchLifeline: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()

  /// Whether iOS started this process because the phone moved, rather than
  /// because a rider tapped the icon. Read once and cleared: see
  /// [consumeLaunch].
  private var launchedByLocation = false

  /// The most recent fix the significant-change service has handed us.
  private var latestFix: CLLocation?

  /// A Dart call waiting for the fix that woke us, and its deadline.
  private var pendingResult: FlutterResult?
  private var deadline: DispatchWorkItem?

  override init() {
    super.init()
    manager.delegate = self
    // Significant location change monitoring ignores both of these. They are
    // set anyway so that nothing about this manager rests on a default: it must
    // never pause itself, and it must never be mistaken for the 1 Hz stream the
    // ride runs on.
    manager.pausesLocationUpdatesAutomatically = false
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// Records whether this launch came from the location service, and restarts
  /// monitoring if it did.
  ///
  /// THE RESTART IS REQUIRED, not defensive. Apple's contract is that a
  /// relaunched app must call `startMonitoringSignificantLocationChanges` again
  /// to receive the event that woke it. Without this line the app would be
  /// started, learn nothing, and go back to sleep, which is a worse failure
  /// than not being started at all because it looks like it worked.
  func noteLaunch(options: [UIApplication.LaunchOptionsKey: Any]?) {
    guard options?[.location] != nil else { return }
    launchedByLocation = true
    manager.startMonitoringSignificantLocationChanges()
  }

  /// Arm. Called when a ride starts, and idempotent by the platform's own
  /// contract.
  func arm() -> String? {
    guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
      return "significant location change monitoring unavailable"
    }
    manager.startMonitoringSignificantLocationChanges()
    return nil
  }

  /// Disarm. Called when a ride ends, by whichever half of the app noticed.
  func disarm() {
    manager.stopMonitoringSignificantLocationChanges()
  }

  /// Answers the one question Dart asks at launch, and clears the flag so a
  /// second caller cannot be told the same story twice.
  ///
  /// WAITS FOR THE FIX, up to [seconds]. The location that caused the launch
  /// arrives at the delegate a moment AFTER monitoring is restarted, so a
  /// caller answered synchronously would be told "iOS woke us" and handed no
  /// position, which is the one combination that cannot be acted on. The budget
  /// is small on purpose: a background relaunch gets seconds of runtime, not
  /// minutes.
  func consumeLaunch(seconds: Double, result: @escaping FlutterResult) {
    let woke = launchedByLocation
    launchedByLocation = false

    if !woke || latestFix != nil {
      result(answer(woke: woke))
      return
    }

    // Only one caller is ever expected. If a second arrives, the first is
    // answered with what we have rather than left hanging: a FlutterResult that
    // is never called leaks a Dart future for the life of the process.
    finishPending()

    pendingResult = result
    let timeout = DispatchWorkItem { [weak self] in
      self?.finishPending()
    }
    deadline = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
  }

  /// Posts a notification Dart wrote the words for.
  ///
  /// THE OFF-CORRIDOR ANSWER. A rider who finished the journey another way is
  /// not on the rail corridor, and starting a ride for them would announce
  /// stations at somebody sitting at home. They get told, once, that Travel
  /// Mode stopped, and the app waits to be opened.
  func notify(title: String, body: String, result: @escaping FlutterResult) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      // A FIXED IDENTIFIER, so a phone woken repeatedly on one dead ride
      // replaces its own notification instead of stacking a column of them.
      identifier: "commute_guardian.relaunch",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      // Back to the platform thread. A FlutterResult called from the
      // notification centre's own queue is a documented way to crash.
      DispatchQueue.main.async {
        result(error?.localizedDescription)
      }
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let fix = locations.last else { return }
    latestFix = fix
    finishPending()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Nothing to do but stop waiting. The answer carries the authorization
    // word, which is what a failure here usually turns out to mean.
    finishPending()
  }

  /// Answers a waiting Dart call, once, and cancels its deadline.
  private func finishPending() {
    guard let waiting = pendingResult else { return }
    pendingResult = nil
    deadline?.cancel()
    deadline = nil
    waiting(answer(woke: true))
  }

  private func answer(woke: Bool) -> [String: Any] {
    var payload: [String: Any] = [
      "launchedByLocation": woke,
      "authorization": authorizationWord(),
      "available": CLLocationManager.significantLocationChangeMonitoringAvailable(),
    ]
    if let fix = latestFix {
      payload["lat"] = fix.coordinate.latitude
      payload["lng"] = fix.coordinate.longitude
      // NEGATIVE MEANS INVALID in Core Location, and it is passed through
      // rather than cleaned up here: Dart treats a fix that will not state its
      // accuracy as the worst case, which is a decision and belongs there.
      payload["accuracyM"] = fix.horizontalAccuracy
      payload["ageSeconds"] = -fix.timestamp.timeIntervalSinceNow
    }
    return payload
  }

  private func authorizationWord() -> String {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    switch status {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whenInUse"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }
}

/// Registers `commute_guardian/relaunch` on [registry]'s engine.
///
/// ON BOTH ENGINES, like the thermal channel and for a mirror of its reason.
/// The SERVICE arms and disarms the lifeline, because the service owns both
/// edges of a ride and is the only half that runs when the rider's screen is
/// off. The IMPLICIT engine answers the relaunch, because after a kill the
/// service isolate is exactly what no longer exists.
///
/// FILE SCOPE, NOT A METHOD ON AppDelegate: `setPluginRegistrantCallback` takes
/// a C function pointer and its closure may capture nothing, `self` included.
/// CI answered that with "a C function pointer cannot be formed from a closure
/// that captures context" once already, on 18 Aug 2026, and that round trip
/// costs a macOS runner.
private func registerRelaunchChannel(with registry: FlutterPluginRegistry) {
  guard let registrar = registry.registrar(forPlugin: "relaunch") else { return }
  let channel = FlutterMethodChannel(
    name: "commute_guardian/relaunch",
    binaryMessenger: registrar.messenger()
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "arm":
      result(relaunchLifeline.arm())
    case "disarm":
      relaunchLifeline.disarm()
      result(nil)
    case "consumeLaunch":
      let seconds = (call.arguments as? NSNumber)?.doubleValue ?? 4.0
      relaunchLifeline.consumeLaunch(seconds: seconds, result: result)
    case "notify":
      let arguments = call.arguments as? [String: Any]
      let title = arguments?["title"] as? String ?? ""
      let body = arguments?["body"] as? String ?? ""
      relaunchLifeline.notify(title: title, body: body, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
