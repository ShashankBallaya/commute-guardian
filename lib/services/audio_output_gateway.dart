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
        AudioDeviceType.usbAudio =>
          true,
        _ => false,
      };
}
