import 'dart:io';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/widgets/line_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      expect(
        LineWindow.around(repo, 'kurla')!.stationNames,
        first.stationNames,
      );
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

  test(
    'THE TRUNK STOPS AT AN AMBIGUOUS JUNCTION rather than picking a branch',
    () {
      // Kalyan carries two through services, Kasara and Karjat. From the trunk
      // there is no single answer to what lies beyond it, and a strip that picked
      // one would be telling a Karjat rider about Kasara.
      final window = LineWindow.around(_repo(), 'kalyan')!;

      expect(window.stationNames.last, 'Kalyan');
      expect(window.currentIndex, LineWindow.size - 1);
    },
  );

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
    expect(
      window.continuesAfter,
      isTrue,
      reason: 'Kasara and Karjat are past it',
    );
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

  group('THE WINDOW CROSSFADES WHEN THE RIDER MOVES, 27 Aug 2026', () {
    Widget strip(LineWindow window, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        home: Scaffold(body: LineStrip(window: window)),
      ),
    );

    const before = LineWindow(
      stationNames: ['Thane', 'Kalwa', 'Mumbra', 'Diva', 'Kopar'],
      currentIndex: 2,
      continuesBefore: true,
      continuesAfter: true,
    );
    const after = LineWindow(
      stationNames: ['Kalwa', 'Mumbra', 'Diva', 'Kopar', 'Dombivli'],
      currentIndex: 2,
      continuesBefore: true,
      continuesAfter: true,
    );

    // NEVER pumpAndSettle IN THIS GROUP. The halo repeats for the life of the
    // widget, so there is no quiet frame to settle to and pumpAndSettle times
    // out after ten seconds. Pump explicit frames instead, which is what
    // measuring a 200 ms transition wants anyway.
    testWidgets('both windows are on screen mid-transition', (tester) async {
      await tester.pumpWidget(strip(before));
      await tester.pump();
      expect(find.text('Thane'), findsOneWidget);
      expect(find.text('Dombivli'), findsNothing);

      await tester.pumpWidget(strip(after));
      await tester.pump();
      // PART WAY THROUGH, which is the whole point: an instant swap would
      // never show the two together.
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('Thane'),
        findsOneWidget,
        reason: 'the outgoing window is still fading out',
      );
      expect(
        find.text('Dombivli'),
        findsOneWidget,
        reason: 'and the incoming one is fading in',
      );

      // Past the far end of the 200 ms band.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Thane'), findsNothing);
      expect(find.text('Dombivli'), findsOneWidget);
    });

    testWidgets('REDUCED MOTION SWAPS INSTANTLY, no fade', (tester) async {
      await tester.pumpWidget(strip(before, reduceMotion: true));
      await tester.pump();

      await tester.pumpWidget(strip(after, reduceMotion: true));
      await tester.pump();

      expect(
        find.text('Thane'),
        findsNothing,
        reason: 'a rider who asked for no motion gets the swap, not the fade',
      );
      expect(find.text('Dombivli'), findsOneWidget);
    });

    testWidgets('A REDRAW OF THE SAME WINDOW DOES NOT FADE', (tester) async {
      // The key is what is DRAWN, so an unrelated rebuild (a setState higher
      // up Screen 1, a fix landing that changes nothing) must not blink the
      // strip. This is the guard against keying on something that churns.
      await tester.pumpWidget(strip(before));
      await tester.pump();

      await tester.pumpWidget(strip(before));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Thane'), findsOneWidget);
      expect(find.text('Kalwa'), findsOneWidget);
    });
  });

  group('THE FADE IS PAINTED, not just decided, 1 Sep 2026', () {
    // C10. The window rule above only proves a BOOLEAN. Whether the rail
    // actually fades is a question about a CustomPainter, and no test here
    // could see it: the 30 Aug store screenshot was measured by hand instead
    // (rail contrast falls from 26 to 0 over the last 110 px). These two read
    // the painted pixels, so a refactor that drops the gradient fails here
    // rather than on a rider's phone at Kalyan.

    const width = 400.0;
    const height = 120.0;
    // Five stops across 400 px: dots at 40, 120, 200, 280, 360.
    const lastDotX = 360;

    Future<List<double>> railRow(WidgetTester tester, LineWindow window) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: const Color(0xFF000000),
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: LineStrip(window: window),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // runAsync, because toImage waits on the real engine and a widget test's
      // fake async never lets that future complete: without it the test hangs
      // instead of failing, which cost ten minutes on 1 Sep.
      var imageWidth = 0;
      final data = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        imageWidth = image.width;
        return image.toByteData();
      }))!;
      final w = imageWidth;
      final h = height.round();
      double lum(int x, int y) {
        final i = (y * w + x) * 4;
        return 0.2126 * data.getUint8(i) +
            0.7152 * data.getUint8(i + 1) +
            0.0722 * data.getUint8(i + 2);
      }

      // THE RAIL IS THE ROW THAT IS LIT RIGHT ACROSS THE WIDGET. Picking the
      // brightest row instead finds a label: text is far brighter than a
      // hairline at 16 percent, and it cost two failing runs on 1 Sep.
      var railY = 0;
      var best = -1;
      for (var y = 0; y < h; y++) {
        var lit = 0;
        for (var x = 0; x < w; x += 2) {
          if (lum(x, y) > 1) lit++;
        }
        if (lit > best) {
          best = lit;
          railY = y;
        }
      }
      return [for (var x = 0; x < w; x++) lum(x, railY)];
    }

    testWidgets('the rail fades out past the last dot when the line goes on', (
      tester,
    ) async {
      // Kalyan from the trunk: the strip stops there because Kasara and Karjat
      // both leave it, but the line itself carries on.
      final row = await railRow(
        tester,
        const LineWindow(
          stationNames: ['Diva', 'Kopar', 'Dombivli', 'Thakurli', 'Kalyan'],
          currentIndex: 4,
          continuesBefore: true,
          continuesAfter: true,
        ),
      );

      final atDot = row[lastDotX - 8];
      final justPast = row[lastDotX + 10];
      final atEdge = row[row.length - 2];

      expect(atDot, greaterThan(2), reason: 'rail is drawn at the last dot');
      expect(
        justPast,
        greaterThan(0.5),
        reason: 'the rail carries on past the last dot',
      );
      expect(
        justPast,
        lessThan(atDot),
        reason: 'and it is already fading there',
      );
      // Not zero at the last pixel: the gradient's final stop is transparent
      // AT the edge, so the pixel before it still carries a trace. What
      // matters is that it is nearly gone and still falling.
      expect(atEdge, lessThan(justPast), reason: 'still falling at the edge');
      expect(atEdge, lessThan(2), reason: 'and all but spent');
    });

    testWidgets('the rail stops dead at a real terminus', (tester) async {
      // CSMT. A fade here would promise a stretch of Mumbai that does not
      // exist.
      final row = await railRow(
        tester,
        const LineWindow(
          stationNames: ['Byculla', 'Sandhurst Road', 'Masjid', 'CSMT', 'Kurla'],
          currentIndex: 3,
          continuesBefore: true,
          continuesAfter: false,
        ),
      );

      expect(row[lastDotX - 8], greaterThan(2), reason: 'rail up to the dot');
      expect(
        row[lastDotX + 10],
        lessThan(0.5),
        reason: 'NOTHING is drawn past a terminus',
      );
    });
  });

}
