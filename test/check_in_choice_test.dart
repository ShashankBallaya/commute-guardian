import 'dart:io';

import 'package:commute_guardian/services/check_in_choice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which check-in an iPhone speaks, decided from the ladder's own session note.
///
/// The note comes from AppDelegate.startAckSession, which is Swift and only
/// compiles in CI, so the strings it returns are pinned here from the source.
void main() {
  test('exclusive means the earphone tap reaches us', () {
    expect(earphoneAckFromSessionNote('ladder session exclusive'), isTrue);
  });

  test('ducked or NONE means the rider\'s music owns the buttons', () {
    expect(
      earphoneAckFromSessionNote(
        'ladder session ducked (exclusive refused: CannotInterruptOthers '
        '(560557684))',
      ),
      isFalse,
    );
    expect(
      earphoneAckFromSessionNote(
        'ladder session NONE (exclusive refused: CannotInterruptOthers '
        '(560557684), ducked refused: CannotInterruptOthers (560557684))',
      ),
      isFalse,
    );
  });

  test('any other note is not an answer at all', () {
    expect(earphoneAckFromSessionNote('session handed back'), isNull);
    expect(
      earphoneAckFromSessionNote('tone (re)started, session exclusive'),
      isNull,
      reason: 'a TONE note is a later re-seize, not the ladder-start answer',
    );
    expect(earphoneAckFromSessionNote(''), isNull);
  });

  test('AppDelegate still returns the strings this parses', () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(swift.contains(r'return "ladder session \(seized)"'), isTrue);
    expect(swift.contains('return "exclusive"'), isTrue);
    expect(swift.contains('return "ducked (exclusive refused:'), isTrue);
    expect(swift.contains('return "NONE (exclusive refused:'), isTrue);
  });
}
