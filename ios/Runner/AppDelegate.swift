import AVFoundation
import CallKit
import Flutter
import MediaPlayer
import UIKit
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
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

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
