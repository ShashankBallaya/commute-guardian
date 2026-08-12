import 'package:commute_guardian/services/permissions_gateway.dart';

/// One fake for every test that touches permissions.
///
/// SHARED ON PURPOSE. It used to live inside `onboarding_test.dart`, and the
/// moment the gateway grew battery-optimisation methods on 12 Aug 2026 that
/// private copy broke the analyzer and a second copy would have been the
/// obvious fix. Two fakes drift, and a fake that drifts from the real gateway
/// stops testing anything: the interface it implements is the whole point.
class FakePermissions implements PermissionsGateway {
  FakePermissions({
    this.android = true,
    this.whileInUseGranted = true,
    this.alwaysGranted = false,
    this.notificationsGranted = true,
    this.batteryExempt = false,
  });

  final bool android;

  bool whileInUseGranted;
  bool alwaysGranted;
  bool notificationsGranted;
  bool batteryExempt;

  /// Every call, in order. Tests assert on WHAT WAS ASKED as much as on what
  /// came back: the Android 11+ trap is about which door gets opened, not
  /// about the answer.
  final List<String> asked = [];

  @override
  bool get isAndroid => android;

  @override
  Future<bool> requestWhileInUse() async {
    asked.add('whileInUse');
    return whileInUseGranted;
  }

  @override
  Future<bool> requestAlways() async {
    asked.add('always');
    return alwaysGranted;
  }

  @override
  Future<bool> requestNotifications() async {
    asked.add('notifications');
    return notificationsGranted;
  }

  @override
  Future<bool> openSettings() async {
    asked.add('openSettings');
    return true;
  }

  @override
  Future<bool> hasWhileInUse() async => whileInUseGranted;

  @override
  Future<bool> hasAlways() async => alwaysGranted;

  @override
  Future<bool> hasNotifications() async => notificationsGranted;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => batteryExempt;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    asked.add('requestIgnoreBattery');
    return batteryExempt;
  }

  @override
  Future<bool> openBatterySettings() async {
    asked.add('openBatterySettings');
    return true;
  }
}
