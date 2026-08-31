/// A ride that started and never ended, offered back to the rider at launch.
///
/// THE 16 AUG EXIT RIDE IS WHY THIS EXISTS. iOS killed the app mid-journey and
/// told nobody: the service stopped watching, no announcement was ever spoken
/// again, and the phone in the rider's pocket looked exactly like a phone doing
/// its job. Nothing in the app noticed, because the only question it ever asked
/// was "is a ride running now", and the honest answer after a kill is no.
///
/// IT WAS NOT A JETSAM, which this file said until 18 Aug 2026 and which was
/// never checked. The phone's own report says `0x8BADF00D`, a scene-update
/// watchdog transgression: the main thread spent more than ten seconds
/// archiving UIKit state on the way into the background. Nothing was short of
/// memory. See `ios/Runner/AppDelegate.swift`, which now refuses that archive.
///
/// WHAT THIS CAN AND CANNOT DO, said plainly because it decides how much to
/// build here. `geofencing_api`'s iOS side is a stub and the fences are a Dart
/// engine over the location stream, so NO OS-level region is registered on
/// either platform. **While that stays true, iOS cannot relaunch us after a
/// kill**, resume on reopen is the ONLY recovery available, and it helps a
/// rider who reopens the app and nobody else. This makes the failure VISIBLE
/// and RECOVERABLE. It does not make the ride safe.
///
/// [mayResumeUnattended] is the first half of changing that: given a relaunch,
/// it decides whether the ride may restart without asking. The half that makes
/// iOS relaunch us at all is native, unwritten, and the real work.
library;

import 'dart:math' as math;

import '../models/station.dart';
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
/// Owner's call, 31 Aug 2026: NINETY MINUTES, down from three hours.
///
/// The trade he took, with the cost named: a CSMT run is 27 stations and about
/// 100 minutes, so a long ride killed in its final stretch now falls OUTSIDE
/// the window and is neither offered back nor silently relaunched. That is the
/// last ten minutes of the longest rides on the line, which is also when the
/// wake matters most. Against it, ninety minutes stops the app offering to
/// resume a commute that ended long ago, and since C1 this constant no longer
/// gates only a prompt: inside the window a killed ride can resume UNASKED.
/// It is one constant precisely so it is cheap to change back.
const resumeWindow = Duration(minutes: 90);

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

/// How far a fix lies from the RAIL CORRIDOR the ride was planned along, in
/// metres, or null when the chain is too short to have a corridor.
///
/// Distance to the nearest SEGMENT between consecutive stations, not to the
/// nearest station. A train halfway between Vangani and Shelu is 1.6 km from
/// either one and exactly on the line it is supposed to be on; measuring to
/// stations would call that rider lost.
///
/// Flat-earth projection, on purpose. Over a segment of at most a few
/// kilometres at Mumbai's latitude the error is centimetres, and every consumer
/// of this compares against a threshold of hundreds of metres.
double? distanceToCorridorM(List<Station> chain, double lat, double lng) {
  if (chain.length < 2) return null;
  const metresPerDegreeLat = 111320.0;
  final metresPerDegreeLng =
      metresPerDegreeLat * math.cos(lat * math.pi / 180.0);
  double x(double longitude) => longitude * metresPerDegreeLng;
  double y(double latitude) => latitude * metresPerDegreeLat;

  final px = x(lng), py = y(lat);
  double? best;
  for (var i = 0; i < chain.length - 1; i++) {
    final ax = x(chain[i].lng), ay = y(chain[i].lat);
    final bx = x(chain[i + 1].lng), by = y(chain[i + 1].lat);
    final dx = bx - ax, dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    // Two stations at the same coordinates would divide by zero. It cannot
    // happen in generated data and the guard costs nothing.
    final t = lengthSquared == 0
        ? 0.0
        : (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    final d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
    if (best == null || d < best) best = d;
  }
  return best;
}

/// How far off the corridor a fix may be and still count as "still on this
/// journey", before the fix's own accuracy is added.
///
/// GENEROUS ON PURPOSE, and the number is chosen from the failure it guards
/// rather than from the geometry. Being wrong in one direction restarts a ride
/// for a rider who is on the train and asleep. Being wrong in the other
/// direction announces stations to somebody who went home in a rickshaw. The
/// first costs a little battery, the second costs the rider's trust in the
/// voice, so the test is deliberately hard to fail and the WINDOW is what
/// really bounds it: a stale ride is refused by [interruptedRideFrom] long
/// before this is asked.
///
/// 1500 m also happens to clear the widest thing in the data, the 1200 m
/// interchange approach fence, which is the largest distance at which this app
/// already considers a rider to be "at" a point on their journey.
const corridorToleranceM = 1500.0;

/// Whether a ride may be restarted WITHOUT asking the rider first.
///
/// THE OPPOSITE RULE TO THE SCREEN 1 OFFER, and the difference is evidence.
/// The offer asks, because an app reopened an hour later cannot know whether
/// the rider finished the trip another way. This is for the case where iOS
/// relaunched the app ITSELF because the phone moved, which means the journey
/// is still happening and the rider is probably asleep, which is the whole
/// reason this product exists.
///
/// So it asks for proof rather than assuming: the ride is one
/// [interruptedRideFrom] already accepted, AND the fix that woke us is still on
/// the corridor the ride was planned along. A rider who went home another way
/// is off the corridor and gets nothing, which is the right answer.
///
/// [accuracyM] IS ADDED TO THE TOLERANCE, not compared against it. The fix that
/// relaunches us comes from significant location change monitoring, which is
/// cell and wifi positioning: hundreds of metres of error is normal and it is
/// not a reason to distrust the rider's position, only a reason to widen the
/// question. A fix that will not say its own accuracy is treated as the worst
/// case this app ever sees at 1 Hz.
bool mayResumeUnattended({
  required List<Station> chain,
  required double lat,
  required double lng,
  required double accuracyM,
}) {
  final offCorridor = distanceToCorridorM(chain, lat, lng);
  if (offCorridor == null) return false;
  return offCorridor <= corridorToleranceM + math.max(accuracyM, 0);
}
