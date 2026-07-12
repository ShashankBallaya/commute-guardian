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
    final kalwa = result.firstWhere((a) => a.stationId == 'kalwa');
    expect(kalwa.kind, AnnouncementKind.arrival);
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

  test('reaching a station past the destination is an overshoot warning', () {
    final ride = _newRide();
    ride.onFix(lat: 19.1807762, lng: 72.9944301, accuracyM: 20); // at Digha (destination)

    // Rode on to Airoli, one past the alighting point.
    final result = ride.onFix(lat: 19.1585231, lng: 72.9994023, accuracyM: 20);

    expect(result.map((a) => a.stationId), contains('airoli'));
    final airoli = result.firstWhere((a) => a.stationId == 'airoli');
    expect(airoli.kind, AnnouncementKind.overshoot);
  });
}
