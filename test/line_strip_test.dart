import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/widgets/line_strip.dart';
import 'package:flutter_test/flutter_test.dart';

/// Against the REAL bundled network, like the planner tests: the window rule's
/// whole job is to read the shipped station data, so a toy line would test the
/// wrong thing.
StationRepository _repo() => StationRepository.parse(
  File('assets/stations/mumbai_suburban.json').readAsStringSync(),
);

void main() {
  test('the rider sits in the middle, two either side', () {
    final window = LineWindow.around(_repo(), 'dombivli')!;

    expect(window.stationNames, hasLength(LineWindow.size));
    expect(window.currentIndex, 2);
    expect(window.stationNames[2], 'Dombivli');
  });

  test('AT A TERMINUS THE WINDOW SLIDES, it does not pad with blanks', () {
    // Nothing sits behind CSMT, so the rider is at the top of a full window
    // looking at four ahead. Padding would spend two of five rows on nothing.
    final window = LineWindow.around(_repo(), 'csmt')!;

    expect(window.stationNames, hasLength(LineWindow.size));
    expect(window.currentIndex, 0);
    expect(window.stationNames.first, 'CSMT');
  });

  test('the far end slides the other way', () {
    final window = LineWindow.around(_repo(), 'kasara')!;

    expect(window.stationNames, hasLength(LineWindow.size));
    expect(window.currentIndex, LineWindow.size - 1);
    expect(window.stationNames.last, 'Kasara');
  });

  test('A STATION ON SEVERAL LINES PICKS ONE AND KEEPS PICKING IT', () {
    // Kurla is Central and Harbour. Which one the strip shows matters far less
    // than showing the same one every launch: a window that flips between two
    // lines under a still rider reads as a bug, and this screen has no way to
    // ask which train they are waiting for.
    final repo = _repo();
    final first = LineWindow.around(repo, 'kurla')!;
    for (var i = 0; i < 5; i++) {
      expect(LineWindow.around(repo, 'kurla')!.stationNames, first.stationNames);
    }
    expect(first.stationNames[first.currentIndex], 'Kurla');
  });

  test('no fix, no window', () {
    expect(LineWindow.around(_repo(), null), isNull);
    expect(LineWindow.around(null, 'kurla'), isNull);
  });

  test('THE TWO HALVES OF DADAR SHOW DIFFERENT LINES', () {
    // They are different stations on different lines, and after the 25 Aug
    // rename they are named so. A rider at Dadar Western must not be shown the
    // Central main.
    final repo = _repo();
    final central = LineWindow.around(repo, 'dadar')!;
    final western = LineWindow.around(repo, 'dadar_western')!;

    expect(central.stationNames[central.currentIndex], 'Dadar Central');
    expect(western.stationNames[western.currentIndex], 'Dadar Western');
    expect(central.stationNames, isNot(western.stationNames));
  });

  test('A BRANCH SEES THROUGH ITS JUNCTION ONTO THE TRUNK', () {
    // Found on the 3T rather than here: standing at Shahad the strip drew the
    // rider second from the top, as though nothing existed behind him. Shahad
    // is on the Kasara branch, whose list BEGINS at Kalyan, and a Kasara train
    // runs through Kalyan onto the trunk while the rider sits still.
    final window = LineWindow.around(_repo(), 'shahad')!;

    expect(window.currentIndex, 2, reason: 'centred, not pinned to the top');
    expect(window.stationNames[0], 'Thakurli');
    expect(window.stationNames[1], 'Kalyan');
    expect(window.stationNames[2], 'Shahad');
    expect(window.stationNames[3], 'Ambivli');
  });

  test('THE TRUNK STOPS AT AN AMBIGUOUS JUNCTION rather than picking a branch', () {
    // Kalyan carries two through services, Kasara and Karjat. From the trunk
    // there is no single answer to what lies beyond it, and a strip that picked
    // one would be telling a Karjat rider about Kasara.
    final window = LineWindow.around(_repo(), 'kalyan')!;

    expect(window.stationNames.last, 'Kalyan');
    expect(window.currentIndex, LineWindow.size - 1);
  });

  test('AT A REAL TERMINUS THE RAIL STOPS, it does not fade into nothing', () {
    // CSMT is the end of the Central main. A fade says "there is more line
    // here", and there is not: it would promise a stretch of Mumbai that does
    // not exist. The far end of the same window still fades, because that end
    // really does carry on.
    final window = LineWindow.around(_repo(), 'csmt')!;

    expect(window.continuesBefore, isFalse);
    expect(window.continuesAfter, isTrue);
  });

  test('BOTH ENDS FADE IN THE MIDDLE OF A LINE', () {
    final window = LineWindow.around(_repo(), 'dombivli')!;

    expect(window.continuesBefore, isTrue);
    expect(window.continuesAfter, isTrue);
  });

  test('A TRUNCATED CORRIDOR STILL FADES, because the line does carry on', () {
    // The strip stops at Kalyan from the trunk because two branches leave it
    // and no single strip can draw both. That is OUR limit, not the network's,
    // and a hard stop there would call Kalyan the end of the Central main.
    final window = LineWindow.around(_repo(), 'kalyan')!;

    expect(window.stationNames.last, 'Kalyan');
    expect(window.continuesAfter, isTrue, reason: 'Kasara and Karjat are past it');
  });

  test('THE RIDER IS ALWAYS BELOW THE RAIL, whatever the window does', () {
    // Labels alternate for spacing, and the rule is by INDEX so a name never
    // changes sides as the rider travels. The window puts them at index 2 and
    // slides them to 0 or 4 at a terminus, so every position they can occupy
    // is even.
    for (final index in [0, 2, LineWindow.size - 1]) {
      expect(LineStrip.isBelow(index), isTrue, reason: 'index \$index');
    }
    expect(LineStrip.isBelow(1), isFalse);
    expect(LineStrip.isBelow(3), isFalse);
  });
}
