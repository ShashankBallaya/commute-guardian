import 'package:commute_guardian/models/station.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// OSM station-node coords, transcribed from assets/stations/mumbai_suburban.json
/// (the independent source of truth for expected values). Kalyan -> Digha ride order,
/// with Airoli kept one past the destination as the overshoot backstop.
///
/// The code is irrelevant to RideProgress, which keys off the station id, so these
/// fixtures just reuse the id.
Station _s(String id, String name, double lat, double lng, int radiusM) => Station(
      id: id,
      code: id.toUpperCase(),
      name: name,
      nameHi: name,
      nameMr: name,
      lat: lat,
      lng: lng,
      radiusM: radiusM,
    );

final _chain = <Station>[
  _s('kalyan', 'Kalyan', 19.2358216, 73.1308101, 500),
  _s('thakurli', 'Thakurli', 19.22611, 73.09811, 400),
  _s('dombivli', 'Dombivli', 19.21815, 73.08673, 450),
  _s('kopar', 'Kopar', 19.21194, 73.07860, 400),
  _s('diva', 'Diva Junction', 19.1887564, 73.0414169, 400),
  _s('mumbra', 'Mumbra', 19.18979, 73.02325, 400),
  _s('kalwa', 'Kalwa', 19.1952243, 72.9963331, 400),
  _s('thane', 'Thane', 19.1864830, 72.9757664, 500),
  _s('digha', 'Digha Gaon', 19.1807762, 72.9944301, 350),
  _s('airoli', 'Airoli', 19.1585231, 72.9994023, 400),
];

/// The 18 Jul evening ride, Ghansoli toward Kalyan: the direction in which the
/// chain doubles back around the Thane creek V (in from Digha in the east, out
/// to Kalwa in the east again). The false-positive regression tests replay the
/// real fixes from that ride's logs.
final _returnChain = <Station>[
  _s('ghansoli', 'Ghansoli', 19.1163113, 73.0070197, 400),
  _s('rabale', 'Rabale', 19.1366355, 73.0027822, 400),
  _s('airoli', 'Airoli', 19.1585231, 72.9994023, 400),
  _s('digha', 'Digha Gaon', 19.1807762, 72.9944301, 350),
  _s('thane', 'Thane', 19.1864830, 72.9757664, 500),
  _s('kalwa', 'Kalwa', 19.1952243, 72.9963331, 400),
  _s('mumbra', 'Mumbra', 19.1899425, 73.0230752, 400),
  _s('diva', 'Diva Junction', 19.1887564, 73.0414169, 400),
  _s('kopar', 'Kopar', 19.2124230, 73.0788650, 400),
  _s('dombivli', 'Dombivli', 19.2180493, 73.0861355, 450),
  _s('thakurli', 'Thakurli', 19.2262813, 73.0980174, 400),
  _s('kalyan', 'Kalyan', 19.2358216, 73.1308101, 500),
];

RideProgress _returnRide() => RideProgress(
      chain: _returnChain,
      destinationStationId: 'kalyan',
      arrivalAnnouncements: const {
        'thane': 'You have reached Thane. Change here to the Central line.',
        'kalyan': 'You have arrived at your destination, Kalyan.',
      },
    );

RideProgress _newRide() => RideProgress(
      chain: _chain,
      destinationStationId: 'digha',
      approachRadiusM: const {'thane': 1200, 'digha': 1000},
      arrivalAnnouncements: const {
        'thane': 'You have reached Thane. Change here for the Trans Harbour line.',
        'digha': 'You have arrived at your destination, Digha.',
      },
    );

void main() {
  test('a fix outside every fence returns no announcements', () {
    final ride = _newRide();

    // Mid-sea point off the Mumbai coast, far from any station on the chain.
    final result = ride.onFix(lat: 18.9000, lng: 72.7000, accuracyM: 20);

    expect(result, isEmpty);
  });

  test('a fix inside the first station returns one arrival for it', () {
    final ride = _newRide();

    // At Kalyan platform (the chain origin).
    final result = ride.onFix(lat: 19.2358216, lng: 73.1308101, accuracyM: 20);

    expect(result, hasLength(1));
    expect(result.single.stationId, 'kalyan');
    expect(result.single.kind, AnnouncementKind.arrival);
  });

  test('a station already arrived is not announced again', () {
    final ride = _newRide();

    ride.onFix(lat: 19.2358216, lng: 73.1308101, accuracyM: 20);
    // Still sitting at Kalyan a moment later.
    final second = ride.onFix(lat: 19.2358216, lng: 73.1308101, accuracyM: 20);

    expect(second, isEmpty);
  });

  test('a two-stage station announces approach on the outer fence, then arrival',
      () {
    final ride = _newRide();

    // ~850 m short of Thane: inside the 1200 m approach fence, outside the
    // 500 m inner fence (the real iPhone approach-trigger fix from the log).
    final approach = ride.onFix(lat: 19.18867, lng: 72.98350, accuracyM: 30);
    expect(approach, hasLength(1));
    expect(approach.single.stationId, 'thane');
    expect(approach.single.kind, AnnouncementKind.approach);

    // Now at the Thane platform: inside the inner fence.
    final arrival = ride.onFix(lat: 19.1864830, lng: 72.9757664, accuracyM: 20);
    expect(arrival, hasLength(1));
    expect(arrival.single.stationId, 'thane');
    expect(arrival.single.kind, AnnouncementKind.arrival);
  });

  test('approaching Thane from Kalwa does not count as having passed Thane', () {
    final ride = _newRide();

    // Established at Kalwa, the station before the interchange.
    ride.onFix(lat: 19.1952243, lng: 72.9963331, accuracyM: 20);

    // The real 12 Jul fix (both phones) at which the ride wrongly spoke the
    // full "You have reached Thane, get off the train" script: still 1.19 km
    // SHORT of Thane, on the Kalwa approach. The chain doubles back at Thane
    // (in from the east on the Central line, out to the east again toward
    // Digha), so a fix short of Thane sits on the same side as the next
    // station and must not be mistaken for one past it.
    final result = ride.onFix(lat: 19.18931, lng: 72.98669, accuracyM: 10);

    expect(
      result.where((a) => a.kind == AnnouncementKind.arrival),
      isEmpty,
      reason: 'the train is 1.19 km short of Thane; it has not arrived',
    );
    expect(result, hasLength(1));
    expect(result.single.stationId, 'thane');
    expect(result.single.kind, AnnouncementKind.approach);

    // Pulling into the Thane platform is what announces the interchange.
    final arrival = ride.onFix(lat: 19.1864830, lng: 72.9757664, accuracyM: 20);
    expect(arrival, hasLength(1));
    expect(arrival.single.stationId, 'thane');
    expect(arrival.single.kind, AnnouncementKind.arrival);
  });

  test('a fence jumped between fixes still announces, late (Kalwa backstop)', () {
    final ride = _newRide();

    // Established at Mumbra.
    ride.onFix(lat: 19.18979, lng: 73.02325, accuracyM: 20);

    // Next usable fix is already ~800 m past Kalwa toward Thane (the real
    // OnePlus 3 min 12 s gap): never inside Kalwa's 400 m fence.
    final result = ride.onFix(lat: 19.19090, lng: 72.99028, accuracyM: 30);

    expect(
      result.map((a) => a.stationId),
      contains('kalwa'),
      reason: 'Kalwa was jumped by the native engine; the backstop must catch it',
    );
    // Spoken as history, not as a live claim: the train is provably beyond
    // Kalwa, and "Now approaching Kalwa" here misled on the 13 Jul ride.
    final kalwa = result.firstWhere((a) => a.stationId == 'kalwa');
    expect(kalwa.kind, AnnouncementKind.passed);
    expect(kalwa.text, 'You have passed Kalwa.');
  });

  test('catching up several stations speaks the jumped ones as passed and the '
      'one the train is at normally (13 Jul blackout)', () {
    final ride = _newRide();

    // Established at Kalyan, then a GPS blackout: the next usable fix lands
    // inside the Dombivli fence, two stations later (the real 3T pattern from
    // the 13 Jul return leg, where Kalwa and Mumbra played back-to-back).
    ride.onFix(lat: 19.2358216, lng: 73.1308101, accuracyM: 20);
    final result = ride.onFix(lat: 19.21815, lng: 73.08673, accuracyM: 30);

    expect(result, hasLength(2));
    expect(result[0].stationId, 'thakurli');
    expect(result[0].kind, AnnouncementKind.passed);
    expect(result[0].text, 'You have passed Thakurli.');
    expect(result[1].stationId, 'dombivli');
    expect(result[1].kind, AnnouncementKind.arrival,
        reason: 'the train really is at Dombivli, so the live text is honest');
  });

  test('a low-accuracy fix is ignored and does not advance progress', () {
    final ride = _newRide();
    ride.onFix(lat: 19.18979, lng: 73.02325, accuracyM: 20); // established at Mumbra

    // A blackout fix sitting on Kalwa but with 600 m accuracy: rejected.
    final blackout = ride.onFix(lat: 19.1952243, lng: 72.9963331, accuracyM: 600);
    expect(blackout, isEmpty);

    // A good fix at Kalwa now still announces it, proving the blackout fix
    // neither announced Kalwa nor advanced the reached pointer past it.
    final good = ride.onFix(lat: 19.1952243, lng: 72.9963331, accuracyM: 20);
    expect(good.map((a) => a.stationId), contains('kalwa'));
  });

  test('an implausible position jump is ignored (Bangalore outlier)', () {
    final ride = _newRide();
    ride.onFix(lat: 19.18979, lng: 73.02325, accuracyM: 20); // established at Mumbra

    // The real Android log spike: a confident (98 m) fix ~840 km away.
    final outlier = ride.onFix(lat: 12.65091, lng: 77.21702, accuracyM: 98);
    expect(outlier, isEmpty);

    // Progress is intact: the next real fix at Kalwa still announces it.
    final good = ride.onFix(lat: 19.1952243, lng: 72.9963331, accuracyM: 20);
    expect(good.map((a) => a.stationId), contains('kalwa'));
  });

  test('a single eliminative fix cannot mark a station passed '
      '(18 Jul false positive)', () {
    final ride = _returnRide();

    // Established at Digha by the real native-fence fix (iPhone, 21:14:58).
    final atDigha = ride.onFix(lat: 19.17772, lng: 72.99391, accuracyM: 14);
    expect(atDigha.map((a) => a.stationId), contains('digha'));

    // The real false-positive fix (iPhone, 21:18:51): 143 m claimed accuracy,
    // actually ~460 m off any track, nearest to Kalwa but not beyond it. The
    // old n - 1 fallback inferred "past Thane" from it and spoke a passed
    // announcement for an interchange the train had not reached, which then
    // deduped the real arrival into silence. Elimination alone must not pass
    // a station on one fix.
    final falseFix = ride.onFix(lat: 19.19028, lng: 72.99541, accuracyM: 143);
    expect(falseFix, isEmpty,
        reason: 'one eliminative fix must wait for corroboration');

    // The real next fix (21:18:59, 28 m) is back inside the Digha fence: it
    // contradicts the pending claim, which must be discarded, not spoken.
    final contradiction =
        ride.onFix(lat: 19.18021, lng: 72.99507, accuracyM: 28);
    expect(contradiction, isEmpty);

    // The train then really reaches Thane (the real ENTER fix, 21:21:26).
    // This is the announcement the false positive silenced on the ride: the
    // interchange script must survive.
    final arrival = ride.onFix(lat: 19.18742, lng: 72.98037, accuracyM: 29);
    expect(arrival, hasLength(1));
    expect(arrival.single.stationId, 'thane');
    expect(arrival.single.kind, AnnouncementKind.arrival);
    expect(arrival.single.text,
        'You have reached Thane. Change here to the Central line.');
  });

  test('agreeing on-track fixes on the Digha to Thane curve still cannot '
      'pass Thane (18 Jul systematic case)', () {
    final ride = _returnRide();

    // Established at Digha.
    ride.onFix(lat: 19.17772, lng: 72.99391, accuracyM: 14);

    // The real 21:19:00 to 21:19:01 iPhone fixes: the train genuinely on the
    // Digha to Thane track, moving at 5.5 m/s, where the rail curve swings
    // closer to Kalwa across the creek than to either Digha or Thane. Two
    // honest consecutive fixes agree on "nearest Kalwa, approaching", so
    // corroboration alone cannot reject the inference; only the per-station
    // check can: neither fix is beyond Thane along Thane's own inbound leg,
    // so Thane must not be declared passed.
    final first = ride.onFix(lat: 19.19025, lng: 72.99497, accuracyM: 61);
    final second = ride.onFix(lat: 19.19028, lng: 72.99495, accuracyM: 39);
    expect(first, isEmpty);
    expect(second, isEmpty,
        reason: 'the fix is not beyond Thane, so Thane is not passed');

    // The real arrival then speaks the interchange script.
    final arrival = ride.onFix(lat: 19.18742, lng: 72.98037, accuracyM: 29);
    expect(arrival, hasLength(1));
    expect(arrival.single.stationId, 'thane');
    expect(arrival.single.kind, AnnouncementKind.arrival);
  });

  test('two agreeing eliminative fixes emit the catch-up '
      '(Rabale, 18 Jul)', () {
    final ride = _returnRide();

    // Established at Ghansoli (the real ride start fix).
    ride.onFix(lat: 19.11671, lng: 73.00683, accuracyM: 20);

    // A 5 min blackout jumped the Rabale fence. The first usable fix (the
    // real 3T fix, 21:10:56) is between Rabale and Airoli, nearest Airoli but
    // not beyond it, so "past Rabale" rests on elimination: held one fix.
    final first = ride.onFix(lat: 19.15122, lng: 73.00109, accuracyM: 110);
    expect(first, isEmpty);

    // The next fix (the real 21:11:09 one) agrees the train has moved on:
    // the catch-up speaks now, 13 s later than the old single-fix behavior.
    final second = ride.onFix(lat: 19.15258, lng: 72.99959, accuracyM: 104);
    expect(second.map((a) => a.stationId), contains('rabale'));
    final rabale = second.firstWhere((a) => a.stationId == 'rabale');
    expect(rabale.kind, AnnouncementKind.passed);
  });

  test('a catch-up with direct evidence still fires on a single fix '
      '(Thakurli wake trigger, 18 Jul)', () {
    final ride = _returnRide();

    // Established at Dombivli by the real native-fence fix.
    ride.onFix(lat: 19.21825, lng: 73.08693, accuracyM: 56);

    // The real 3T catch-up fix (21:56:40): past Thakurli along its inbound
    // leg. Direct geometric evidence, so it must NOT wait for corroboration:
    // this very announcement armed the destination wake ladder on the ride,
    // and delaying it delays the ladder.
    final result = ride.onFix(lat: 19.22682, lng: 73.10193, accuracyM: 56);
    expect(result.map((a) => a.stationId), contains('thakurli'));
    final thakurli = result.firstWhere((a) => a.stationId == 'thakurli');
    expect(thakurli.kind, AnnouncementKind.passed);
  });

  test('reaching a station past the destination is an overshoot warning', () {
    final ride = _newRide();
    ride.onFix(lat: 19.1807762, lng: 72.9944301, accuracyM: 20); // at Digha (destination)

    // Rode on to Airoli, one past the alighting point.
    final result = ride.onFix(lat: 19.1585231, lng: 72.9994023, accuracyM: 20);

    expect(result.map((a) => a.stationId), contains('airoli'));
    final airoli = result.firstWhere((a) => a.stationId == 'airoli');
    expect(airoli.kind, AnnouncementKind.overshoot);
    // The warning fires as the train reaches the station, so it must tell the
    // rider to get off HERE, by name. "Alight at the next station" reads as an
    // instruction to stay on for one more stop.
    expect(airoli.text, 'You have passed your stop. Please alight here, at Airoli.');
  });
}
