import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE REPLAY TOOL IS A SECOND WIRING OF THE SAME ENGINES, and a second wiring
/// drifts. It has now done so twice.
///
/// The first time, it silently stopped passing the overshoot pins, which is why
/// every engine gained a `forJourney` factory. The second time was 29 Aug 2026:
/// `JourneyPlanner` gained `walkCrossings` and the tool kept hand-building the
/// planner without it, so a replay of the 28 Aug ride announced Dadar Western
/// on the wrong side of the bridge while the app on the phone would not have.
/// The same call was also missing `endpointOnlyWalkInterchanges`, which had been
/// quietly wrong for every Parel to Prabhadevi replay.
///
/// A replay that disagrees with the app is worse than no replay: it is the
/// instrument this project judges real rides with, and it says nothing when it
/// is the thing that is wrong.
///
/// The tool cannot simply use [StationRepository], which is the obvious fix,
/// because that reaches the asset bundle through `package:flutter/services.dart`
/// and the tool has to run under plain `dart run`. So the duplication stays, and
/// this test is what stops it rotting.
void main() {
  final planner = File('lib/services/journey_planner.dart').readAsStringSync();
  final tool = File('tool/replay_ride.dart').readAsStringSync();

  /// Source with `//` comments removed.
  ///
  /// WITHOUT THIS THE GUARD IS A LIE: `walkCrossings` is named in the tool's
  /// own commentary, so a plain substring search passes while the parameter is
  /// not passed at all. That is exactly the shape of the five bad guards found
  /// on 20 Aug 2026.
  String stripComments(String code) => code
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment < 0 ? line : line.substring(0, comment);
      })
      .join('\n');

  /// The named parameters of the `JourneyPlanner` constructor, in source order.
  List<String> plannerParameters() {
    final start = planner.indexOf('JourneyPlanner({');
    final end = planner.indexOf('});', start);
    expect(start, greaterThan(-1), reason: 'the constructor must be findable');
    final body = stripComments(planner.substring(start, end));
    return [
      for (final match in RegExp(r'this\.(\w+)').allMatches(body))
        match.group(1)!,
    ];
  }

  /// The tool's hand-built `JourneyPlanner(...)` call.
  String toolCall() {
    final start = tool.indexOf('JourneyPlanner(');
    final end = tool.indexOf(').plan(', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    return stripComments(tool.substring(start, end));
  }

  test('the replay tool passes every JourneyPlanner parameter', () {
    final parameters = plannerParameters();
    expect(
      parameters,
      contains('walkCrossings'),
      reason:
          'the parameter this test was written for must be in the list, '
          'otherwise the guard is checking an empty set',
    );

    final call = toolCall();
    final missing = [
      for (final parameter in parameters)
        if (!RegExp('\\b$parameter:').hasMatch(call)) parameter,
    ];

    expect(
      missing,
      isEmpty,
      reason:
          'tool/replay_ride.dart builds its own JourneyPlanner and is missing '
          '$missing. A replay that plans a different route from the app is an '
          'instrument that lies. Add the argument there too.',
    );
  });

  test('and the guard can still fail', () {
    // The test above is only worth having if a dropped argument breaks it.
    // Prove that against the real parameter list rather than trusting it.
    final parameters = plannerParameters();
    final withOneDropped = stripComments(
      toolCall(),
    ).replaceAll(RegExp(r'\bwalkCrossings:'), 'notThePoint:');

    final missing = [
      for (final parameter in parameters)
        if (!RegExp('\\b$parameter:').hasMatch(withOneDropped)) parameter,
    ];

    expect(missing, ['walkCrossings']);
  });
}
