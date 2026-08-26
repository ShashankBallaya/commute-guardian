/// Asking iOS to start the app again after it has killed a ride, and deciding
/// what to do when it does.
///
/// THE HOLE THIS FILLS. `geofencing_api`'s iOS side is a 20-line stub, so this
/// app registers no OS-level region and iOS has never had a reason to relaunch
/// it. Everything built for the 16 Aug 2026 kill so far, the in-flight flag,
/// [interruptedRideFrom], the offer on Screen 1, helps a rider who OPENS THE
/// APP. A rider asleep with the phone in a pocket, who is the entire reason
/// this product exists, still got silence. `mayResumeUnattended` was written
/// as the first half of changing that and has had no caller since.
///
/// This is the second half. Significant location change monitoring is the one
/// iOS service that survives termination: the system holds the registration,
/// and starts the app again, in the background, once the phone has moved far
/// enough. See `RelaunchLifeline` in ios/Runner/AppDelegate.swift.
///
/// WHAT IT IS NOT. It is not a promise that a killed ride comes back. iOS
/// decides when a change is significant (roughly a cell handover, so typically
/// hundreds of metres and minutes, not seconds), it may decline to start us at
/// all under memory pressure, and a phone that never moves again is never a
/// trigger. A train doing 60 km/h between Mumbai stations crosses cells often,
/// which is the case this is aimed at. Treat it as a lifeline, not a seatbelt.
///
/// ANDROID DOES NOT HAVE THIS AND DOES NOT NEED IT. The foreground service
/// survives, and where an OEM kills it the answer is the battery-killer
/// guidance, not a relaunch. The channel simply does not exist there, which
/// every method below treats as "no lifeline" rather than as an error.
library;

import 'package:flutter/services.dart';

import '../models/station.dart';
import 'ride_resume.dart';

/// What iOS said when the app asked why it had been started.
class RelaunchAnswer {
  const RelaunchAnswer({
    required this.launchedByLocation,
    this.lat,
    this.lng,
    this.accuracyM,
    this.ageSeconds,
    this.authorization,
    this.available = false,
  });

  /// A launch nobody can attribute to movement: a rider tapping the icon, a
  /// test, or a platform with no lifeline at all.
  static const none = RelaunchAnswer(launchedByLocation: false);

  factory RelaunchAnswer.fromPlatform(Map<Object?, Object?>? payload) {
    if (payload == null) return none;
    double? number(String key) => (payload[key] as num?)?.toDouble();
    return RelaunchAnswer(
      launchedByLocation: payload['launchedByLocation'] == true,
      lat: number('lat'),
      lng: number('lng'),
      accuracyM: number('accuracyM'),
      ageSeconds: number('ageSeconds'),
      authorization: payload['authorization'] as String?,
      available: payload['available'] == true,
    );
  }

  /// Whether iOS started this process because the phone moved.
  final bool launchedByLocation;

  final double? lat;
  final double? lng;

  /// Core Location's horizontal accuracy, in metres. NEGATIVE MEANS INVALID
  /// there, and it arrives unchanged: what to do about a fix that will not
  /// state its own accuracy is a decision, and decisions live on this side.
  final double? accuracyM;

  /// How old the fix was when it was read.
  final double? ageSeconds;

  /// `always`, `whenInUse`, `denied`, `restricted`, `notDetermined`. Recorded
  /// rather than acted on: a lifeline that is silently unauthorized looks
  /// exactly like a lifeline that was never needed, and this is the only line
  /// that can tell those apart in a ride log.
  final String? authorization;

  /// Whether the platform offers significant location change monitoring.
  final bool available;

  bool get hasFix => lat != null && lng != null;

  /// One line for the ride log. Coordinates are NOT in it: the log is exported
  /// and mailed, and no fix ever leaves this phone.
  String describe() =>
      'relaunch: byLocation=$launchedByLocation, fix=$hasFix, '
      'accuracy=${accuracyM?.round()}m, age=${ageSeconds?.round()}s, '
      'auth=$authorization, available=$available';
}

/// What the app should do about a relaunch.
enum RelaunchAction {
  /// Nothing happened worth acting on: an ordinary launch, or a wake with no
  /// ride behind it.
  ignore,

  /// Start the ride again WITHOUT asking, because the evidence says the
  /// journey is still happening.
  resume,

  /// Tell the rider Travel Mode stopped, and wait to be opened. The answer
  /// whenever the app was woken for a ride it cannot prove is still running.
  notify,
}

/// The accuracy assumed for a fix that will not state its own.
///
/// 150 m is this app's own ceiling for a usable fix at 1 Hz
/// (`RideProgress.maxAccuracyM`, and the same number in `WakeEscalation` and
/// `WindDown`). Using it here means an unstated accuracy is treated as the
/// worst fix the app would ever act on, rather than as a perfect one.
const unstatedAccuracyM = 150.0;

/// The whole decision, and it is pure on purpose.
///
/// EVERY JUDGEMENT IS HERE, none of it in Swift. Swift does not compile on the
/// machine this project is written on, so a rule placed there costs a macOS
/// runner every time it is wrong, and can never be reproduced at a desk. This
/// function needs no phone, no channel and no isolate.
///
/// THE RULE, agreed before it was built: auto-resume on relaunch, but ONLY
/// against evidence. Off-corridor gets a notification, not a ride.
///
/// - Not woken by movement: nothing to do. The rider is holding the phone and
///   Screen 1's offer is the right surface, not a background decision.
/// - Woken with no interrupted ride: nothing to do. [interruptedRideFrom] has
///   already refused a ride that is stale, finished, or never had a route.
/// - Woken, ride present, NO FIX: notify. Being told is honest; starting a
///   ride on no evidence is how a rider at home gets announcements.
/// - Woken, ride present, fix ON the corridor: resume, in silence. This is the
///   sleeping rider, and asking them is exactly what cannot be done.
/// - Woken, ride present, fix OFF the corridor: notify. They went home another
///   way, and an alarm for a journey already over is what teaches riders to
///   ignore the voice.
RelaunchAction relaunchActionFor({
  required RelaunchAnswer answer,
  required InterruptedRide? ride,
  required List<Station> chain,
}) {
  if (!answer.launchedByLocation) return RelaunchAction.ignore;
  if (ride == null) return RelaunchAction.ignore;
  if (!answer.hasFix) return RelaunchAction.notify;

  final stated = answer.accuracyM;
  // Negative is Core Location's "this reading is invalid". So is a missing
  // one. Both mean the same thing to this decision and get the same answer.
  final accuracyM = (stated == null || stated < 0) ? unstatedAccuracyM : stated;

  final onCorridor = mayResumeUnattended(
    chain: chain,
    lat: answer.lat!,
    lng: answer.lng!,
    accuracyM: accuracyM,
  );
  return onCorridor ? RelaunchAction.resume : RelaunchAction.notify;
}

/// What the rider reads when the app was woken and could not prove the ride.
///
/// IT DOES NOT SAY "TAP TO RESUME", because a notification cannot know whether
/// they are still travelling. It states what happened and leaves the choice on
/// Screen 1, where the resume offer already lives and where declining also
/// writes the History row.
const relaunchNotificationTitle = 'Travel Mode stopped';
const relaunchNotificationBody =
    'Your phone ended the ride. Open Commute Guardian to pick it back up.';

/// The platform edge. A CLASS SO IT CAN BE FAKED, like every other one here.
class RelaunchLifeline {
  const RelaunchLifeline();

  static const _channel = MethodChannel('commute_guardian/relaunch');

  /// How long the platform may wait for the fix that woke us.
  ///
  /// The fix arrives at the delegate a moment AFTER monitoring restarts, so
  /// answering instantly would report "iOS woke us" with no position, which is
  /// the one combination this app cannot act on. Four seconds against a
  /// background relaunch budget measured in seconds, not minutes.
  static const launchFixWait = Duration(seconds: 4);

  /// Arms or disarms the lifeline, matching the in-flight flag.
  ///
  /// TIED TO `rideInFlightKey` BY CONSTRUCTION rather than by discipline: the
  /// two are written together in `writeRideInFlight`, so there is no path that
  /// starts a ride without a lifeline or leaves one armed after an ending the
  /// app chose. A lifeline left armed would be a phone woken for a ride that
  /// is over, which is only battery, but it would also be a lie in the log.
  Future<String?> setArmed(bool armed) async {
    try {
      return await _channel.invokeMethod<String>(armed ? 'arm' : 'disarm');
    } catch (_) {
      // Android, a test binding, or an iOS build without the channel. All of
      // them mean "no lifeline", which is the state this app has been in since
      // it was written and is never a reason to fail a ride.
      return null;
    }
  }

  /// Why this process was started, asked once.
  ///
  /// NEVER THROWS INTO A LAUNCH. This runs on the way into the app, so an
  /// error here would be a white screen, and this project has already shipped
  /// one of those.
  Future<RelaunchAnswer> consumeLaunch() async {
    try {
      final payload = await _channel.invokeMethod<Map<Object?, Object?>>(
        'consumeLaunch',
        launchFixWait.inSeconds,
      );
      return RelaunchAnswer.fromPlatform(payload);
    } catch (_) {
      return RelaunchAnswer.none;
    }
  }

  /// Posts the one notification, and returns the platform's complaint if it
  /// refused.
  Future<String?> notifyRideStopped() async {
    try {
      return await _channel.invokeMethod<String>('notify', {
        'title': relaunchNotificationTitle,
        'body': relaunchNotificationBody,
      });
    } catch (_) {
      return null;
    }
  }
}
