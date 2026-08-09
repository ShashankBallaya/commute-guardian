import '../models/app_settings.dart';
import 'spoken_copy.dart';

/// What a [RideTimeout] wants done. Mirrors WindDown's shape on purpose: the
/// engine decides, the service performs.
sealed class RideTimeoutAction {
  const RideTimeoutAction();
}

/// Say this out loud, once.
class RideTimeoutSpeak extends RideTimeoutAction {
  const RideTimeoutSpeak(this.text);
  final String text;
}

/// End Travel Mode. Same teardown the wind-down auto-off runs.
class RideTimeoutEnd extends RideTimeoutAction {
  const RideTimeoutEnd();
}

/// A line for the ride log, and nothing else.
class RideTimeoutNote extends RideTimeoutAction {
  const RideTimeoutNote(this.reason);
  final String reason;
}

/// The four-hour backstop: a ride nobody ended.
///
/// The handover's TIMEOUT edge transition (section 4.1), built 5 Aug 2026 and
/// the last Phase 1 item that was on no other list.
///
/// IT IS NOT THE SAME BACKSTOP AS WINDDOWN. WindDown ends a ride that ARRIVED,
/// once the rider has provably walked away from the platform. This one is for
/// the ride that never arrives: geofences missed all the way down the line, or
/// the rider got off somewhere the app was not watching and put their phone in
/// a pocket. On 22 Jul the owner walked home from Shahad with both phones still
/// streaming GPS, which is exactly this, and the only thing that ended it was
/// him remembering.
///
/// FOUR HOURS IS PAST ANY REAL RIDE ON THIS NETWORK. CSMT to Kasara, the
/// longest run in the bundled data, is a little over three hours with the
/// stopping pattern. So four hours does not mean a slow train; it means nobody
/// is coming back to end this.
///
/// TWO THINGS IT WILL NOT DO, and they are the whole safety argument:
///
///   It never ends a ride while the WAKE LADDER IS LIVE. An alarm sounding is
///   the app doing the one job it exists for, and a timeout that silenced it
///   would be the worst bug this project could ship. A rider asleep past their
///   stop with the alarm climbing is precisely the state that can also be four
///   hours old.
///
///   It never ends a ride while a WIND-DOWN COUNTDOWN is running, because that
///   ride is already ending, by an engine that knows where the rider is
///   standing. Two teardowns racing is how the 4 Aug double-pop happened.
///
/// In both cases the clock keeps running rather than being cancelled: the ride
/// ends on the tick after the alert does.
class RideTimeout {
  RideTimeout({required this.startedAt, this.language = AppLanguage.english});

  /// What the one warning is spoken in.
  final AppLanguage language;

  /// When the ride started. Read from the SHARED STORE by the caller, never
  /// from a field a restarted service would have lost: an OS recreation
  /// mid-ride must not hand a forgotten ride a fresh four hours.
  final DateTime startedAt;

  /// Long enough that no real ride on this network is still running, and the
  /// first thing that happens is a sentence, not a teardown.
  static const warnAfter = Duration(hours: 4);

  /// Half an hour later. The gap is there so a rider who IS still aboard (a
  /// stalled line, a diversion) hears the warning and can act on it, rather
  /// than losing Travel Mode with no notice at all.
  static const endAfter = Duration(hours: 4, minutes: 30);

  bool _warned = false;
  bool _ended = false;

  /// Whether the log already carries the reason the end is being held. At five
  /// second ticks, "once per tick" would be 720 identical lines an hour in a
  /// file that is read by eye.
  bool _holdNoted = false;

  /// One tick. [wakeLadderLive] and [windDownLive] are passed rather than held
  /// because they are facts about right now, the same way PocketPulse takes
  /// `announcerBusy`.
  List<RideTimeoutAction> onTick(
    DateTime now, {
    required bool wakeLadderLive,
    required bool windDownLive,
  }) {
    if (_ended) return const [];
    final elapsed = now.difference(startedAt);

    if (elapsed >= endAfter) {
      if (wakeLadderLive || windDownLive) {
        if (_holdNoted) return const [];
        _holdNoted = true;
        return [
          RideTimeoutNote(
            'end held: ${wakeLadderLive ? 'wake ladder' : 'wind-down'} live',
          ),
        ];
      }
      // Cleared so a second hold, after a first one lifted, is logged too.
      _holdNoted = false;
      _ended = true;
      return [
        RideTimeoutNote('${elapsed.inMinutes} min with no end, stopping'),
        const RideTimeoutEnd(),
      ];
    }

    if (elapsed >= warnAfter && !_warned) {
      _warned = true;
      return [
        RideTimeoutNote('${elapsed.inMinutes} min with no end, warning'),
        // Says what will happen and what to do about it. A rider still aboard
        // has half an hour to answer it, and one who is not will simply never
        // hear it.
        RideTimeoutSpeak(SpokenCopy(language).rideTimeoutWarning()),
      ];
    }

    return const [];
  }
}
