import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// The one door to the permission plugins, for the same reason
/// RideServiceClient is the one door to the service isolate: every method here
/// reaches a platform channel that does not exist under the widget-test
/// binding, so onboarding would be untestable without a seam.
///
/// Deliberately dumb. It asks and it reports; it holds no opinion about what
/// the rider should be asked next, which is the screen's job.
class PermissionsGateway {
  const PermissionsGateway();

  /// Foreground location. On Android 11+ this is ALL the system will grant in
  /// one dialog, whatever else is requested alongside it.
  Future<bool> requestWhileInUse() async =>
      (await Permission.locationWhenInUse.request()).isGranted;

  Future<bool> hasWhileInUse() async =>
      Permission.locationWhenInUse.status.then((s) => s.isGranted);

  /// Background location, the grant this whole product depends on.
  ///
  /// On Android 11+ asking here does NOT show a dialog with an "Allow all the
  /// time" option; the OS sends the rider to Settings instead. That is why
  /// onboarding has a screen for it rather than a prompt, and why the screen
  /// tells them which label to hunt for.
  Future<bool> requestAlways() async =>
      (await Permission.locationAlways.request()).isGranted;

  Future<bool> hasAlways() async =>
      Permission.locationAlways.status.then((s) => s.isGranted);

  /// Android 13+ needs this at runtime. The foreground-service notification is
  /// how a rider reaches End now and Extend, so a refusal costs them controls,
  /// not just noise.
  Future<bool> requestNotifications() async =>
      (await Permission.notification.request()).isGranted;

  Future<bool> hasNotifications() async =>
      Permission.notification.status.then((s) => s.isGranted);

  /// Opens the app's settings page, for the background-location upgrade the OS
  /// refuses to grant from a dialog.
  Future<bool> openSettings() => openAppSettings();

  bool get isAndroid => Platform.isAndroid;
}
