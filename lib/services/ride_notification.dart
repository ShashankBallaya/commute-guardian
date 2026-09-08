import '../models/app_settings.dart';
import '../models/station.dart';

/// The second line of the ongoing Travel Mode notification, rebuilt every time
/// the ride's position changes.
///
/// A FREE FUNCTION BECAUSE THE CALL SITE CANNOT BE TESTED, the same reason
/// `alarm_volume_answer.dart` is one. The only caller is inside the foreground
/// service isolate and ends in a `FlutterForegroundTask.updateService` call,
/// which needs a platform. The wording is the part worth pinning, so the
/// wording is what lives here.
///
/// WHAT IT REPLACES. One notification was set at ride start, "Shahad to
/// Karjat", and never touched again, so a locked phone said the same thing at
/// Shahad as it did at Parel a hundred minutes later. The plugin owns this
/// notification on BOTH platforms (iOS since 11 Aug 2026,
/// `IOSNotificationOptions.showNotification`), so this one line is also the
/// iPhone lock screen.
///
/// THERE IS NO ETA IN IT, and that is a decision, not an omission. A live
/// on-device estimate was decided on 12 Jul 2026 and scoped to Phase 3 on
/// 29 Jul rather than shipped as a fabricated time: a wrong arrival time is
/// worse than no arrival time in a product whose entire promise is about when
/// to wake somebody. See `TravelModeScreen.etaLine`, the seam it will land on.
String rideProgressLine({
  required List<Station> chain,
  required int reachedIndex,
  required bool atStation,
  required AppLanguage language,
}) {
  // NOTHING HERE MAY THROW. The only caller runs in the foreground service
  // isolate, which has no screen, so an exception is SILENT: the ride stops
  // watching and the rider finds out by missing their stop. Every index below
  // is bounded rather than trusted, including the empty chain that cannot
  // happen and the index one past the end that can, because the arrival fires
  // before teardown finishes.
  if (chain.isEmpty) return '';
  // CLAMPED AT THE ORIGIN, NOT AT -1, and that decides what the count means.
  // reachedIndex is -1 until the origin's own fence is crossed, and a rider
  // standing on the Kalyan platform is not going to ride TO Kalyan. Counting
  // from the origin makes "stops to go" mean the same thing before boarding
  // as after it.
  final reached = reachedIndex.clamp(0, chain.length - 1);
  final remaining = chain.length - 1 - reached;

  // Arrived. There is nothing left to count and the ride is about to end.
  if (remaining <= 0) return 'At ${chain[reached].nameIn(language)}';

  // THE LAST LEG NAMES THE ARRIVAL RATHER THAN COUNTING IT. "1 stops to go"
  // is the tell of a counter nobody read on a phone, and the rider on that leg
  // does not want a number anyway: they want to know the next doors that open
  // are theirs.
  final tail = remaining <= 1 ? 'your stop' : '$remaining stops to go';

  // AT a station names the platform the rider can see out of the window, which
  // is the one thing they can check the app against. Between stations there is
  // nothing to check, so it names what is coming instead.
  if (atStation) {
    return 'At ${chain[reached].nameIn(language)}, $tail';
  }
  return 'Next: ${chain[reached + 1].nameIn(language)}, $tail';
}
