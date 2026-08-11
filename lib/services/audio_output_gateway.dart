import 'package:audio_session/audio_session.dart';


/// Where the rider's audio would actually come out right now.
///
/// A SEAM for the same reason [PermissionsGateway] is one: the plugin does not
/// answer under the test binding, and this sits on the ride-start path where a
/// hang would cost a journey.
///
/// Audio through earphones is the PRIMARY channel on both platforms (see
/// CLAUDE.md), so "are they even plugged in" is the single most useful thing
/// this app can check before a rider falls asleep.
class AudioOutputGateway {
  const AudioOutputGateway();

  /// Below this the rider is told their volume is low.
  ///
  /// 30 PERCENT, AND THE NUMBER IS A COMPROMISE BETWEEN TWO FAILURES. Too high
  /// and the warning fires before ordinary rides, which is the failure this
  /// screen's own rule names: a rider who learns to tap past Screen 3 taps past
  /// the one that mattered. Too low and it only catches a muted phone, which is
  /// not the only way to sleep through an alarm.
  ///
  /// At 30 percent the ladder's own first rung (0.3 of system volume) lands
  /// near 9 percent of full scale, which is inaudible in a carriage. It is not
  /// tuned against a measurement, because no measurement exists yet; the ride
  /// log now records the volume at every start, so a later session can tune it
  /// against real rides instead of against this paragraph.
  static const lowVolume = 0.3;

  /// READING THE VOLUME LIVES ON [RideServiceClient], not here, and the reason
  /// is architectural rather than tidiness.
  ///
  /// It needs the native media channel, and exactly one file on the UI side is
  /// allowed to touch that (enforced by `isolate_boundary_test.dart`). Putting
  /// it here also hid a runtime bug: the service isolate called it to log the
  /// volume at ride start, and a channel registered on the MAIN engine is
  /// unreachable from the service's own engine, so it would have returned null
  /// on every real ride while passing every test. The volume now crosses to the
  /// service through the store, like the language and the pulse settings.

  /// True when audio would reach earphones, wired or Bluetooth.
  ///
  /// FAILS OPEN. If the probe throws, times out, or the platform will not say,
  /// this returns true, which suppresses the warning rather than showing a
  /// rider a problem we cannot actually confirm. A false alarm before every
  /// ride would train them to tap past the screen that matters.
  Future<bool> earphonesConnected() async {
    try {
      final session = await AudioSession.instance;
      final devices = await session
          .getDevices(includeInputs: false)
          .timeout(const Duration(seconds: 2));
      if (devices.isEmpty) return true;
      return devices.any((device) => _reachesEars(device.type));
    } catch (_) {
      return true;
    }
  }

  /// Anything the rider could plausibly have in or over their ears.
  ///
  /// bluetoothSco is included deliberately: a mono headset is a poor way to
  /// hear a station name and a perfectly good way to hear an alarm, which is
  /// the job that matters here.
  ///
  /// AudioDeviceType IS MARKED EXPERIMENTAL in audio_session 0.2.4, so this
  /// enum can change under a version bump. The ignore is deliberate and the
  /// blast radius is contained: the gateway fails open, so if this ever stops
  /// compiling or starts lying, the cost is a warning the rider does not see,
  /// never a ride that does not start.
  // ignore_for_file: experimental_member_use
  static bool _reachesEars(AudioDeviceType type) => switch (type) {
    AudioDeviceType.wiredHeadset ||
    AudioDeviceType.wiredHeadphones ||
    AudioDeviceType.bluetoothA2dp ||
    AudioDeviceType.bluetoothSco ||
    AudioDeviceType.usbAudio => true,
    _ => false,
  };
}
