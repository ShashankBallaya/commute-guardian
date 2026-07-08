import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commute_guardian/main.dart';

void main() {
  testWidgets('Geofence debug screen shows start/stop controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CommuteGuardianDebugApp());
    await tester.pump();

    expect(find.text('Start Travel Mode'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNWidgets(2));
  });
}
