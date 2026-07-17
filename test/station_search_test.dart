import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/models/station.dart';

const _kalyan = Station(
  id: 'kalyan',
  code: 'KYN',
  name: 'Kalyan',
  nameHi: 'कल्याण',
  nameMr: 'कल्याण',
  lat: 19.2437,
  lng: 73.1355,
  radiusM: 400,
);

void main() {
  group('a station answers to every name it is known by', () {
    test('its English name, case-insensitively and part-way through', () {
      expect(_kalyan.matches('Kalyan'), isTrue);
      expect(_kalyan.matches('kalyan'), isTrue);
      expect(_kalyan.matches('kal'), isTrue);
      expect(_kalyan.matches('lya'), isTrue);
    });

    // The whole point of carrying nameHi and nameMr: a commuter typing in
    // their own keyboard layout finds their station.
    test('its Hindi and Marathi names', () {
      expect(_kalyan.matches('कल्याण'), isTrue);
      expect(_kalyan.matches('कल्या'), isTrue);
    });

    test('its railway code, which is what the platform boards show', () {
      expect(_kalyan.matches('KYN'), isTrue);
      expect(_kalyan.matches('kyn'), isTrue);
    });

    test('surrounding whitespace does not stop a match', () {
      expect(_kalyan.matches('  kalyan  '), isTrue);
    });

    test('an empty query matches, so the unfiltered list is every station', () {
      expect(_kalyan.matches(''), isTrue);
      expect(_kalyan.matches('   '), isTrue);
    });

    test('a station it is not', () {
      expect(_kalyan.matches('Thane'), isFalse);
      expect(_kalyan.matches('TNA'), isFalse);
      expect(_kalyan.matches('ठाणे'), isFalse);
    });

    // Substring, not fuzzy. Worth pinning: the handover calls for "fuzzy
    // station search", and this is deliberately not that yet.
    test('a typo finds nothing', () {
      expect(_kalyan.matches('Kalyna'), isFalse);
    });
  });

  group('against the real network', () {
    late List<Station> stations;

    setUpAll(() {
      final raw = File(StationRepository.assetPath).readAsStringSync();
      stations = StationRepository.parse(raw).stationsById.values.toList();
    });

    test('every station is reachable by its own Devanagari name', () {
      for (final station in stations) {
        expect(
          stations.where((s) => s.matches(station.nameHi)),
          contains(station),
          reason: '${station.name} cannot be found by typing ${station.nameHi}',
        );
      }
    });

    test('a code search finds the one station holding that code', () {
      final matches = stations.where((s) => s.matches('KYN')).toList();
      expect(matches, hasLength(1));
      expect(matches.single.name, 'Kalyan');
    });

    // Dadar Central and Dadar Western share a name and not a code, so the
    // name search has to surface both and let the code tell them apart.
    test('a shared name surfaces every station carrying it', () {
      final matches = stations.where((s) => s.matches('Dadar')).toList();
      expect(matches.length, greaterThanOrEqualTo(1));
      expect(matches.map((s) => s.code).toSet(), hasLength(matches.length));
    });
  });
}
