import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE SCREEN MAY NOT PROMISE MORE WARNING THAN THE ENGINE GIVES.
///
/// From the day the wake card was written until 4 Sep 2026 it said "2 stations
/// before Kalyan". WakeEscalation has always armed at `chain[targetIndex - 1]`,
/// the station IMMEDIATELY before the critical one, which the locked design
/// settled in three separate decisions and which its own tests already assert.
/// So the rider was told to expect roughly twice the warning the alarm actually
/// gives, and 4005 shipped to twelve testers saying it.
///
/// NOTHING CAUGHT IT BECAUSE NOTHING COMPARED THE TWO. The wording lived in a
/// display-only enum that nothing consumed, the engine lived behind its own
/// green tests, and a claim with no test behind it goes stale in silence. Same
/// shape as the 4004/4005 version line on 1 Sep 2026.
///
/// THE ENGINE IS NOT THE THING TO CHANGE IF THIS EVER FAILS. An early ladder
/// does not merely annoy, it SPENDS the alarm: on the 21 Aug 2026 Bandra to
/// Kalyan ride an early wake near Diva was acknowledged, and that
/// acknowledgement resolved Kalyan, so the alarm that mattered could never
/// fire. Firing two stations out doubles the gap between the acknowledgement
/// and the stop, which is time to fall asleep again with the alarm used up.
/// **If this test goes red, fix the sentence.**
///
/// Same enforcement-by-test pattern as isolate_boundary_test.dart and
/// analytics_test.dart, and it carries their lesson too: match what you mean,
/// tolerate anything `dart format` may legally do, and prove the guard can
/// still fail. The last group does that.
void main() {
  group('the wake card and the wake engine state the same rule', () {
    final engineSource = File(
      'lib/services/wake_escalation.dart',
    ).readAsStringSync();
    final screenSource = File(
      'lib/screens/travel_mode_screen.dart',
    ).readAsStringSync();
    // CLAUDE.md IS GITIGNORED AND UNTRACKED (.gitignore:50), so it exists on
    // the owner's machine and nowhere else. CI checks out a tree without it.
    // The claim is still worth guarding, because the owner's machine is the
    // only place that line is ever edited, but this half of the guard is a
    // DESK guard and CI proves nothing about it. Say so rather than let a
    // green CI run imply cover it does not give.
    final claudeMd = File('CLAUDE.md');

    test('the engine arms exactly one station before the critical one', () {
      expect(
        _engineOffset(engineSource),
        1,
        reason:
            'WakeEscalation no longer arms at chain[targetIndex - 1]. That is '
            'a change to the LOCKED wake design, not a refactor: read the '
            'escalation decisions and the 21 Aug 2026 ride before going on.',
      );
    });

    test('THE SENTENCE ON THE CARD MATCHES THE ENGINE', () {
      final promised = _screenPromise(screenSource);
      final offset = _engineOffset(engineSource);
      expect(
        promised.count,
        offset,
        reason:
            'The ride screen says "${promised.text}" and the ladder arms '
            '$offset station(s) out. Change the SENTENCE, never the engine.',
      );
    });

    test('and it counts in the plural the rider would use', () {
      final promised = _screenPromise(screenSource);
      expect(
        promised.plural,
        promised.count != 1,
        reason: '"${promised.text}" does not agree with itself',
      );
    });

    test('no WakeChoice name claims a count the engine does not keep', () {
      // The enum member was called `lastTwoStations` until 4 Sep 2026. A name
      // is a claim in the place every reader looks first, so it is guarded
      // like the sentence.
      final offset = _engineOffset(engineSource);
      for (final member in _wakeChoiceMembers(screenSource)) {
        final claimed = _countWordIn(member);
        if (claimed == null) continue;
        expect(
          claimed,
          offset,
          reason:
              'WakeChoice.$member names $claimed station(s) and the engine '
              'arms $offset out',
        );
      }
    });

    test('CLAUDE.md CLAIMS THE SAME NUMBER THE ENGINE KEEPS', () {
      // The third home of this claim, and the one that drifted longest: the
      // locked monetization line said "the pre-warning at two stations" from
      // 30 Jul to 4 Sep 2026. It sets the FREE TIER, so it is a pricing claim
      // as well as a safety one, and the owner was once argued out of shipping
      // exactly the tier the engine was already giving.
      if (!claudeMd.existsSync()) {
        markTestSkipped('CLAUDE.md is not in the checkout (gitignored)');
        return;
      }
      final claimed = _claimedInClaudeMd(claudeMd.readAsStringSync());
      expect(
        claimed,
        _engineOffset(engineSource),
        reason:
            'CLAUDE.md sells a pre-warning at $claimed station(s) and the '
            'ladder arms ${_engineOffset(engineSource)} out. The doc moves, '
            'never the engine.',
      );
    });

    test('the files the guard reads are really there', () {
      // Every regex below finds nothing in an empty string, so a moved or
      // renamed file would turn this whole guard green by doing nothing.
      expect(engineSource, contains('class WakeEscalation'));
      expect(screenSource, contains('enum WakeChoice'));
      expect(_wakeChoiceMembers(screenSource), isNotEmpty);
      if (claudeMd.existsSync()) {
        expect(claudeMd.readAsStringSync(), contains('pre-warning at'));
      }
    });
  });

  group('THE GUARD CAN STILL FAIL, proved rather than assumed', () {
    test('the engine offset is read, not assumed', () {
      expect(
        _engineOffset('''
          if (!_ladderLive &&
              targetIndex > 2 &&
              announcement.stationId == chain[targetIndex - 2].id) {
            return _startLadder(now);
          }
        '''),
        2,
      );
    });

    test('a wrapped line still reads, because dart format may wrap it', () {
      expect(_engineOffset('chain[\n  targetIndex -\n      1\n].id'), 1);
    });

    test('the offset must be the SAME everywhere the engine uses it', () {
      // onStationEvent and the post-call catch-up both index the chain this
      // way. If one moves and the other does not, the ride has two rules and
      // no single sentence can describe it.
      expect(
        () => _engineOffset(
          'chain[targetIndex - 1].id; chain[targetIndex - 2].id;',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a comment can never satisfy either side', () {
      // analytics_test.dart and isolate_boundary_test.dart were each broken
      // once by their own explanatory prose.
      expect(
        () => _engineOffset('// chain[targetIndex - 1] is the trigger'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _screenPromise(
          "/// it used to say '2 stations before \$destinationName'",
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the screen count is read, not assumed', () {
      final two = _screenPromise(
        "WakeChoice.oneStationBefore => '2 stations before \$destinationName',",
      );
      expect(two.count, 2);
      expect(two.plural, isTrue);

      final one = _screenPromise(
        "WakeChoice.oneStationBefore => '1 station before \$destinationName',",
      );
      expect(one.count, 1);
      expect(one.plural, isFalse);
    });

    test('the short-route line is not mistaken for a count', () {
      // 'as you approach X' promises no number, and must not read as zero.
      expect(
        () => _screenPromise(
          "WakeChoice.oneStationBefore when chainLength <= 2 =>\n"
          "  'as you approach \$destinationName',",
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('two counting sentences are a failure, not a coin toss', () {
      expect(
        () => _screenPromise(
          "'1 station before \$destinationName'; '2 stations before \$x'",
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the CLAUDE.md claim is read in words, and read once', () {
      // The doc writes the number in words, not digits, and it is the only
      // place the phrase may appear: two of them is a doc arguing with itself.
      expect(_claimedInClaudeMd('the pre-warning at one station**.'), 1);
      expect(_claimedInClaudeMd('**the pre-warning at two stations**.'), 2);
      expect(
        () => _claimedInClaudeMd(
          'Plus sells the CHOICE of pre-warning '
          'distance.',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _claimedInClaudeMd(
          'pre-warning at one station, and the pre-warning at two stations',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a count word is matched as a WORD inside the identifier', () {
      // `onlyDestination` holds neither "one" nor "two", and a bare substring
      // test on the lowercased name would be the 8 Aug 2026 bug again.
      expect(_countWordIn('onlyDestination'), isNull);
      expect(_countWordIn('oneStationBefore'), 1);
      expect(_countWordIn('lastTwoStations'), 2);
      expect(_countWordIn('threeStationsOut'), 3);
    });

    test('the member list ignores the enum doc comments', () {
      expect(
        _wakeChoiceMembers('''
          /// Warned two stations out.
          enum WakeChoice {
            /// The one before.
            oneStationBefore,

            /// Only the destination.
            onlyDestination,
          }
        '''),
        ['oneStationBefore', 'onlyDestination'],
      );
    });
  });
}

/// How many stations before the critical one the ladder arms, read out of
/// wake_escalation.dart.
///
/// Every `chain[targetIndex - N]` in the file must name the same N. There are
/// two of them today, the live trigger in onStationEvent and the post-call
/// catch-up. `\s*` sits at every join because dart format is allowed to wrap
/// the expression, and a guard that breaks on a line wrap teaches its reader to
/// reformat code to please a test.
int _engineOffset(String source) {
  final matches = RegExp(
    r'chain\s*\[\s*targetIndex\s*-\s*(\d+)\s*\]',
  ).allMatches(_stripComments(source));
  final offsets = matches.map((m) => int.parse(m.group(1)!)).toSet();
  if (offsets.length != 1) {
    throw StateError(
      'expected one chain[targetIndex - N] offset in wake_escalation.dart, '
      'found $offsets',
    );
  }
  return offsets.single;
}

/// The counting sentence on the wake card: its number, and whether it says
/// "stations" or "station".
///
/// Blind on purpose to the short-route arm ("as you approach X"), which
/// promises no count at all, and intolerant on purpose of two counting
/// sentences: a card with two of them has drifted whatever the numbers say.
({int count, bool plural, String text}) _screenPromise(String source) {
  final matches = RegExp(
    r"'(\d+) (stations?) before ",
  ).allMatches(_stripComments(source)).toList();
  if (matches.length != 1) {
    throw StateError(
      'expected exactly one "N station(s) before" line in '
      'travel_mode_screen.dart, found ${matches.length}',
    );
  }
  final match = matches.single;
  return (
    count: int.parse(match.group(1)!),
    plural: match.group(2) == 'stations',
    text: match.group(0)!.replaceAll("'", '').trim(),
  );
}

/// The number of stations of warning CLAUDE.md sells to the free tier.
///
/// Written in words there, not digits, and it must appear exactly once: a
/// locked decision that states its own number twice is a decision arguing with
/// itself. Deliberately does NOT match "the CHOICE of pre-warning distance",
/// which is the Plus line and names no count.
int _claimedInClaudeMd(String source) {
  final matches = RegExp(
    r'pre-warning at ([a-z]+) stations?',
  ).allMatches(source).toList();
  if (matches.length != 1) {
    throw StateError(
      'expected exactly one "pre-warning at N station(s)" claim in CLAUDE.md, '
      'found ${matches.length}',
    );
  }
  final claimed = _countWordIn(matches.single.group(1)!);
  if (claimed == null) {
    throw StateError(
      'CLAUDE.md says "pre-warning at ${matches.single.group(1)} station", '
      'which names no number this guard understands',
    );
  }
  return claimed;
}

/// The member names of `enum WakeChoice`, comments removed.
List<String> _wakeChoiceMembers(String source) {
  final body = RegExp(
    r'enum\s+WakeChoice\s*\{(.*?)\}',
    dotAll: true,
  ).firstMatch(_stripComments(source));
  if (body == null) return const [];
  return body
      .group(1)!
      .split(',')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();
}

/// The number a camelCase identifier claims, or null if it claims none.
///
/// The case boundaries are split first, so this asks whether the name CONTAINS
/// THE WORD rather than the letters: `onlyDestination` holds no "one", and a
/// bare substring test is exactly what broke two guards on 8 Aug 2026.
int? _countWordIn(String identifier) {
  const words = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5};
  final parts = identifier
      .replaceAllMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), (_) => ' ')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'));
  for (final part in parts) {
    final value = words[part];
    if (value != null) return value;
  }
  return null;
}

String _stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment == -1 ? line : line.substring(0, comment);
    })
    .join('\n');
