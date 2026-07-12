import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:flutter_test/flutter_test.dart';

StationRepository _repo() => StationRepository.parse(
      File(StationRepository.assetPath).readAsStringSync(),
    );

void main() {
  test('the nearest station to a platform is that station', () {
    // Standing on the Kalyan platform.
    final nearest = _repo().nearestStation(19.2358216, 73.1308101);
    expect(nearest.id, 'kalyan');
  });

  test('distanceToM measures how far a fix really is from a station', () {
    final repo = _repo();
    final kalyan = repo.station('kalyan');

    expect(repo.distanceToM(kalyan, kalyan.lat, kalyan.lng), lessThan(1));

    // The real 12 Jul indoor fix that made the debug build auto-select "Taloja
    // Panchanand" as the origin while the phone sat at home near Shahad: a fix
    // this far from the station it names must never be trusted to start a ride.
    final taloja = repo.station('taloja');
    final distance = repo.distanceToM(taloja, 19.2439, 73.1664);
    expect(distance, greaterThan(3000));
  });
}
