import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_notification.dart';
import 'package:flutter_test/flutter_test.dart';

/// THE LINE ON A LOCKED PHONE, C5's cheap half.
///
/// Until now one notification was set at ride start, "Shahad to Karjat", and
/// never touched again, so a locked phone said the same thing at Shahad as at
/// Parel for a hundred minutes. The plugin owns this notification on BOTH
/// platforms, so this one line is also the iPhone lock screen.
///
/// NO ETA, and that is a decision rather than an omission. There is no ETA
/// anywhere in this codebase; it was scoped to Phase 3 on 29 Jul 2026 rather
/// than shipped as a fabricated time, because a wrong arrival time is worse
/// than none in a product whose whole promise is when to wake you.
void main() {
  final chain = [
    _s('kalyan', 'Kalyan'),
    _s('thakurli', 'Thakurli'),
    _s('dombivli', 'Dombivli'),
    _s('kopar', 'Kopar'),
    _s('diva', 'Diva Junction'),
  ];

  test('mid-ride it names the next station and what is left', () {
    // Two stations reached (Kalyan, Thakurli), the train is between Thakurli
    // and Dombivli.
    expect(
      rideProgressLine(
        chain: chain,
        reachedIndex: 1,
        atStation: false,
        language: AppLanguage.english,
      ),
      'Next: Dombivli, 3 stops to go',
    );
  });

  test('the last leg counts no stops, it names the arrival', () {
    // "1 stops to go" is the tell of a counter written by somebody who never
    // read it on a phone. The rider on the last leg does not want a number
    // either; they want to know the next door that opens is theirs.
    expect(
      rideProgressLine(
        chain: chain,
        reachedIndex: 3,
        atStation: false,
        language: AppLanguage.english,
      ),
      'Next: Diva Junction, your stop',
    );
  });

  test('standing at a station says WHERE, not what is next', () {
    // The service publishes at-station separately from the index precisely
    // because a train sits in a platform for a minute and then leaves, and
    // Screen 4 already draws the difference. A rider who wakes and glances at
    // a locked phone while the doors are open wants the name of the platform
    // they can see, which is the one thing they can check against.
    expect(
      rideProgressLine(
        chain: chain,
        reachedIndex: 2,
        atStation: true,
        language: AppLanguage.english,
      ),
      'At Dombivli, 2 stops to go',
    );
  });

  test('before the first fence is crossed it counts from the origin', () {
    // reachedIndex is -1 from the moment the ride starts until the origin's
    // own fence is crossed, which on a walk-up ride is several minutes of a
    // locked phone showing the one line that never changed.
    //
    // THE COUNT MEANS "FROM WHERE YOU ARE", which is what settles this case.
    // The rider standing on the Kalyan platform is not going to ride TO
    // Kalyan, so the next station is Thakurli and four stops are left. The
    // alternative, counting the origin the rider is standing on, makes the
    // number mean something different before boarding than after it.
    expect(
      rideProgressLine(
        chain: chain,
        reachedIndex: -1,
        atStation: false,
        language: AppLanguage.english,
      ),
      'Next: Thakurli, 4 stops to go',
    );
  });

  test('THE END OF THE CHAIN CANNOT THROW, because this runs where a crash is silent', () {
    // The only caller is the foreground service isolate, which has no screen,
    // so an exception there stops the ride watching and the rider finds out by
    // missing their stop. The destination reached is a real state: the arrival
    // fires and teardown is not instant, so an index one past the end must
    // produce a sentence rather than a RangeError.
    expect(
      rideProgressLine(
        chain: chain,
        reachedIndex: 4,
        atStation: true,
        language: AppLanguage.english,
      ),
      'At Diva Junction',
    );
  });
}

Station _s(String id, String name) => Station(
  id: id,
  code: id.toUpperCase(),
  name: name,
  nameHi: name,
  nameMr: name,
  lat: 0,
  lng: 0,
  radiusM: 500,
);
