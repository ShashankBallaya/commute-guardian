import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/onboarding_screen.dart' show permissionsGatewayProvider;
import '../services/oem_guidance.dart';
import '../services/permissions_gateway.dart';

/// What the app can actually promise about waking a rider, read from the
/// platform rather than assumed.
///
/// WHY THIS EXISTS AT ALL. Settings' readiness card is the first card on the
/// screen, and it is first deliberately: OEM battery killers are this project's
/// named top product risk, and a rider whose app was killed mid-journey has no
/// other way to find out. Until 12 Aug 2026 that card was three hardcoded
/// literals (`ride_orchestration.dart`, `readiness: const [...]`), so it showed
/// green for location on a phone where the rider had just revoked it, and amber
/// for battery on a phone that was already exempt. The values were all readable
/// the whole time: onboarding uses [PermissionsGateway], and the service logs
/// the battery state at every ride start where only a developer sees it.
class TravelReadiness {
  const TravelReadiness({
    required this.locationAlways,
    required this.notifications,
    required this.batteryExempt,
  });

  /// Background location. The grant this whole product depends on.
  final bool locationAlways;

  /// Carries the ride's only UI-independent controls. On iOS it is also the
  /// only acknowledgement route that survives the app being swiped away.
  final bool notifications;

  /// Whether Android has exempted the app from battery optimisation.
  ///
  /// NULL MEANS THE QUESTION DOES NOT APPLY, not that the answer is unknown.
  /// iOS has no such setting, so there is nothing to report and nothing a
  /// rider could fix, and the card must leave the row out entirely rather than
  /// show a row that can never go green.
  final bool? batteryExempt;
}

/// Reads all three. A FutureProvider rather than a stream: these change only
/// when the rider goes to system settings and comes back, and there is no
/// lifecycle observer anywhere in this app to notice that. The Fix buttons
/// invalidate this provider when they return, which covers the one path that
/// changes them from inside the app.
final travelReadinessProvider = FutureProvider<TravelReadiness>((ref) async {
  final gateway = ref.watch(permissionsGatewayProvider);
  // Sequential, not parallel. Three platform channel reads on a cold Settings
  // open, on phones as old as the 3T; the ordering is not worth the risk of
  // three simultaneous channel calls for a card the rider is already looking at.
  final locationAlways = await gateway.hasAlways();
  final notifications = await gateway.hasNotifications();
  // `!Platform.isIOS`, never `Platform.isAndroid`. The two are identical on the
  // two platforms this app ships to and differ on the widget-test host, which
  // is neither, so an allow-list would drop this row out of every test and
  // quietly stop checking it. Same rule as the Settings vibration switch.
  final batteryExempt = Platform.isIOS
      ? null
      : await gateway.isIgnoringBatteryOptimizations();
  return TravelReadiness(
    locationAlways: locationAlways,
    notifications: notifications,
    batteryExempt: batteryExempt,
  );
});

/// The phone-brand gateway, behind a provider so a test can be a Redmi.
final oemGatewayProvider = Provider<OemGateway>((ref) => const OemGateway());

/// What this rider's own phone brand does to background apps, and what to tell
/// them about it.
///
/// DELIBERATELY NOT PART OF [travelReadinessProvider]. Readiness reports what
/// the platform can be ASKED, and every row on that card can go green. This one
/// never can: the autostart list has no API. Keeping them apart is what stops
/// a card that means "you are ready" from growing a row that means "we cannot
/// tell". See lib/services/oem_guidance.dart.
///
/// NOT autoDispose: it is read whenever Settings opens and the answer cannot
/// change without a new phone.
final oemGuidanceProvider = FutureProvider<OemGuidance>((ref) async {
  final device = await ref.watch(oemGatewayProvider).describe();
  return oemGuidanceFor(device);
});
