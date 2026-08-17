/// A ride that started and never ended, offered back to the rider at launch.
///
/// THE 16 AUG EXIT RIDE IS WHY THIS EXISTS. iOS jetsammed the app mid-journey
/// and told nobody: the service stopped watching, no announcement was ever
/// spoken again, and the phone in the rider's pocket looked exactly like a
/// phone doing its job. Nothing in the app noticed, because the only question
/// it ever asked was "is a ride running now", and the honest answer after a
/// kill is no.
///
/// WHAT THIS CAN AND CANNOT DO, said plainly because it decides how much to
/// build here. `geofencing_api`'s iOS side is a stub and the fences are a Dart
/// engine over the location stream, so NO OS-level region is registered on
/// either platform, and iOS will never relaunch us after a kill. Resume on
/// reopen is therefore the ONLY recovery available, and it helps a rider who
/// reopens the app and nobody else. This makes the failure VISIBLE and
/// RECOVERABLE. It does not make the ride safe. The only real prevention is
/// not being killed.
library;

import 'ride_service_client.dart';

/// A journey the store still believes is in progress.
///
/// Every field is read back from the shared store, which is what makes this
/// survivable at all: the process that knew these things is dead.
class InterruptedRide {
  const InterruptedRide({
    required this.originId,
    required this.destinationId,
    required this.startedAt,
    required this.reachedIndex,
    this.startBatteryPct,
  });

  final String originId;
  final String destinationId;

  /// When the RIDE began, not when it was resumed. Carried through a resume so
  /// the history row records the journey the rider actually took, and so a
  /// second kill cannot hand the same forgotten ride a fresh staleness window
  /// every time it is picked up.
  final DateTime startedAt;

  /// Battery at the original start, carried for the same reason.
  final int? startBatteryPct;

  /// How far the dead process had provably got. NOT used to seed the resumed
  /// ride: see [ResumeDecision]. It is here so the offer can say where the
  /// rider was, which is the difference between a prompt they trust and one
  /// they dismiss.
  final int reachedIndex;
}

/// How long after its start a ride may still be offered back.
///
/// A CSMT run is 27 stations and about 100 minutes; three hours covers that
/// with room for a train held outside a terminus, and stops well short of
/// offering to resume this morning's commute at dinner. Owner's call, 17 Aug
/// 2026, and it is one constant precisely so it is cheap to change.
const resumeWindow = Duration(hours: 3);

/// Whether the store is describing a ride that was interrupted, and which one.
///
/// PURE, and that is the point: this is the whole decision, it runs at the desk
/// with no plugin, no isolate and no phone, and the tests that pin it are the
/// only place a kill can be reproduced on demand.
///
/// [serviceRunning] false plus [PersistedRide.rideInFlight] true is the
/// discriminator. The service writes the flag true as it starts and false in
/// `onDestroy`, which runs when the rider ends a ride and when the OS reclaims
/// the service, but did NOT run on the 16 Aug kill: completed rides end with a
/// farewell and "Geofence chain stopped" in the log, the killed one just stops.
InterruptedRide? interruptedRideFrom(
  PersistedRide persisted, {
  required bool serviceRunning,
  required DateTime now,
}) {
  // A running ride is not an interrupted one. liveRideProvider owns that case
  // and this must never offer to start a second service beside it.
  if (serviceRunning) return null;
  if (!persisted.rideInFlight) return null;

  final originId = persisted.originId;
  final destinationId = persisted.destinationId;
  final startedAt = persisted.startedAt;
  // A flag with no ride behind it is a store race or a half-cleared key, not a
  // journey. Offering to resume it would start a service with nowhere to go.
  if (originId == null || destinationId == null || startedAt == null) {
    return null;
  }

  // The rider was told they had arrived. Whatever happened after that, the
  // journey they came for is over, and an alarm for it would be noise.
  if (persisted.destinationReached) return null;

  // Stale, or dated forward by a clock change. Both mean the same thing here:
  // we cannot claim to know this ride is still happening.
  final age = now.difference(startedAt);
  if (age.isNegative || age > resumeWindow) return null;

  return InterruptedRide(
    originId: originId,
    destinationId: destinationId,
    startedAt: startedAt,
    startBatteryPct: persisted.startBatteryPct,
    reachedIndex: persisted.reachedIndex,
  );
}
