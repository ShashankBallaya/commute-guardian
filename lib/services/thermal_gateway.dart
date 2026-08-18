import 'package:flutter/services.dart';

/// How hot the phone says it is, in the platform's own words.
///
/// THE INSTRUMENT THE 16 AUG 2026 KILL NEEDED AND DID NOT HAVE. That crash
/// report shows `Thermal Level: 7, Thermal State: serious`, with the system at
/// 67 percent CPU and this app at 0.084 seconds, 0 percent. We were blocked on
/// a phone that was already slow, and that is how a ten second watchdog
/// deadline became reachable at all.
///
/// It is the only thermal reading this project has ever had. It was taken at
/// the moment of death, and there is nothing to compare it against: nobody
/// knows what a NORMAL ride looks like, how far in the phone starts climbing,
/// or whether it is already "serious" before the wake ladder fires, which is
/// the moment it must not be.
///
/// Ordered, and the order is the point: a ride log can say "it climbed".
enum ThermalState {
  nominal,
  fair,
  serious,
  critical;

  /// iOS `ProcessInfo.ThermalState` raw values, 0 to 3, in this order.
  static ThermalState? fromRaw(int? raw) =>
      raw == null || raw < 0 || raw >= values.length ? null : values[raw];
}

/// Reads [ThermalState] from the platform.
///
/// A CLASS SO IT CAN BE FAKED, like every other platform edge in this project.
/// The ride runs in the service isolate, which cannot reach a channel
/// registered on the implicit engine (that is why the alarm volume is read at
/// Start and carried across the store). So `commute_guardian/thermal` is
/// registered on BOTH engines: see `registerThermalChannel` in
/// ios/Runner/AppDelegate.swift.
class ThermalGateway {
  const ThermalGateway();

  static const _channel = MethodChannel('commute_guardian/thermal');

  /// The current state, or null when the platform will not say.
  ///
  /// NULL RATHER THAN A PLATFORM CHECK, deliberately. Android has an equivalent
  /// (`PowerManager.getCurrentThermalStatus`) from API 29, and the 3T is API 28,
  /// so a `Platform.isIOS` guard here would be an allow-list that quietly
  /// excludes the day somebody wires Android up. A missing handler answers null
  /// on its own, which is the same answer and needs no maintenance.
  ///
  /// NEVER THROWS INTO A RIDE. This is called from the service isolate on a
  /// timer, and an unhandled error there is the one this project has learned to
  /// fear: the isolate whose death is silent.
  Future<ThermalState?> read() async {
    try {
      final raw = await _channel.invokeMethod<int>('getThermalState');
      return ThermalState.fromRaw(raw);
    } catch (_) {
      return null;
    }
  }
}
