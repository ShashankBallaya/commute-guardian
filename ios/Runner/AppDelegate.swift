import AVFoundation
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
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startSession":
        self?.startAckSession()
        result(nil)
      case "stopSession":
        self?.stopAckSession()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    mediaAckChannel = channel
  }

  private func startAckSession() {
    guard ackTargets.isEmpty else { return }

    // Exclusive playback is what earns remote-command routing. The rider's
    // music is interrupted (paused); stand-down hands it back.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      NSLog("WakeAck: could not seize the audio session: \(error)")
    }

    startKeepAlive()

    // Without a Now Playing card some iOS versions still treat the previous
    // music app as the remote target. Rate 1.0 marks us as actively playing.
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: "Commute Guardian wake alert",
      MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]

    let center = MPRemoteCommandCenter.shared()
    let commands: [MPRemoteCommand] = [
      center.playCommand,
      center.pauseCommand,
      center.togglePlayPauseCommand,
      center.nextTrackCommand,
      center.previousTrackCommand,
    ]
    for command in commands {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.mediaAckChannel?.invokeMethod("ack", arguments: nil)
        return .success
      }
      ackTargets.append((command, target))
    }
  }

  private func stopAckSession() {
    for (command, target) in ackTargets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    ackTargets = []

    stopKeepAlive()
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
