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

    // A fix near Shahad is nowhere near Taloja, 30 km away across the network.
    // This is what the origin guard leans on: a station can be the NEAREST one to
    // a fix and still be far too far away to be where the rider is standing.
    final taloja = repo.station('taloja');
    final distance = repo.distanceToM(taloja, 19.2439, 73.1664);
    expect(distance, greaterThan(3000));
  });
}
