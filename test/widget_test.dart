import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/data/station_repository.dart';
import 'package:commute_guardian/main.dart';

/// Brings the screen up with the real station network loaded.
///
/// The repository is read straight off disk rather than through `rootBundle`,
/// because the asset bundle does real I/O and real I/O cannot make progress
/// inside the fake-async zone that `pump` runs in: the pickers would come up
/// empty and disabled, and the whole screen would be untestable.
Future<void> _pumpScreen(WidgetTester tester) async {
  final raw = File(StationRepository.assetPath).readAsStringSync();
  await tester.pumpWidget(
    CommuteGuardianDebugApp(
      loadRepository: () async => StationRepository.parse(raw),
    ),
  );
  await tester.pumpAndSettle();

  final origin = tester.widget<TextField>(
    find.widgetWithText(TextField, 'Origin'),
  );
  expect(
    origin.enabled,
    isTrue,
    reason: 'station data never loaded, so the pickers are disabled',
  );
}

/// Picks [station] in the [label] picker: the field opens a search sheet, and
/// searching is the only way to reach a row here, the rest are never built.
Future<void> _pick(WidgetTester tester, String label, String station) async {
  await tester.tap(find.widgetWithText(TextField, label));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Search stations'),
    station,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, station));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ride cannot be started until one has been picked', (
    tester,
  ) async {
    await _pumpScreen(tester);

    expect(find.text('Pick an origin and a destination.'), findsOneWidget);

    // Starting the service with no journey would run a ride nobody chose. The
    // button stays dead until JourneyPlanner has actually planned one.
    final start = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start journey'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('picking an origin and destination plans and offers the ride', (
    tester,
  ) async {
    await _pumpScreen(tester);

    await _pick(tester, 'Origin', 'Kalyan');
    await _pick(tester, 'Destination', 'Thane');

    // The planned ride is shown before Start, so a wrong pick is caught on the
    // platform rather than thirty minutes into the wrong train.
    expect(find.textContaining('Kalyan → Thakurli'), findsOneWidget);
    expect(find.textContaining('No change of train.'), findsOneWidget);

    final start = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start journey'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('a ride that needs a train change says so before you start', (
    tester,
  ) async {
    await _pumpScreen(tester);

    await _pick(tester, 'Origin', 'Kalyan');
    await _pick(tester, 'Destination', 'Digha Gaon');

    expect(
      find.textContaining('Change at Thane onto Trans Harbour (platform 9, 10, or 10 A)'),
      findsOneWidget,
    );
  });
}
