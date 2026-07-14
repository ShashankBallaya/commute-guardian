import Flutter
import MediaPlayer
import UIKit
import flutter_foreground_task

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Wake escalation earphone-tap acknowledgment (W1 spike). While a ladder
  /// is live, every remote command (AirPods tap, inline click, lock-screen
  /// control) means "I'm awake" and is forwarded to Dart. Routing requires
  /// this app to be the now-playing owner, which the looping alarm tone on
  /// the playback category makes true. NOT compiled locally (no Mac in the
  /// loop); lands with the next IPA cycle and may cost a CI iteration.
  private var mediaAckChannel: FlutterMethodChannel?
  private var ackTargets: [(MPRemoteCommand, Any)] = []

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
    }
    ackTargets = []
  }
}
