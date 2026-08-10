import 'dart:io';

import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/services/announcement_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every en-IN template renders its exact approved sentence', () {
    // Pinned to literals on purpose. These sentences are a contract, not an
    // implementation detail: the Sarvam clips were cut from them, so drift
    // here silently demotes every station back to the device TTS floor.
    expect(ClipKind.approach.render('Thane'), 'Now approaching Thane.');
    expect(ClipKind.passed.render('Rabale'), 'You have passed Rabale.');
    expect(
      ClipKind.destination.render('Nerul'),
      'You have arrived at your destination, Nerul.',
    );
    expect(
      ClipKind.overshoot.render('Shahad'),
      'You have passed your stop. It is alright. Please alight here, '
      'at Shahad.',
    );
    expect(
      WakeLine.wakeUpStop.render('Kalyan'),
      'Wake up! Wake up. Your stop, Kalyan, is next.',
    );
    expect(FixedLine.goodAwake.render(), 'Good, you are awake.');
    expect(
      FixedLine.farewell.render(),
      'Thank you for using Commute Guardian.',
    );
  });

  test('English stays the default, so an unset language cannot go silent', () {
    // Every engine takes the language as an optional parameter defaulting to
    // English, which is what keeps 500-odd existing tests and the replay tool
    // byte-identical. If that default ever moves, this fails first.
    expect(
      ClipKind.approach.render('Thane'),
      ClipKind.approach.render('Thane', language: AppLanguage.english),
    );
  });

  test('clip kinds keep the filename fragments the pack was cut with', () {
    expect(ClipKind.values.map((k) => k.fileSuffix), [
      'approach',
      'passed',
      'overshoot',
      'destination',
    ]);
    expect(WakeLine.values.map((k) => k.fileSuffix), [
      'wake_checkin',
      // The interchange check-in has no clip and never had one: the pack cuts
      // a check-in for the destination only.
      null,
      'wake_up_stop',
      'wake_up_change',
    ]);
    expect(FixedLine.values.map((k) => k.fileSuffix), [
      'farewell',
      'good_awake',
    ]);
  });

  test('every language renders a different sentence for every kind', () {
    // The failure this catches is a copy-paste one: a switch arm that returns
    // the English string under a Devanagari label. It would look right in a
    // diff, pass every other test here, and speak English in a Hindi voice on
    // the ride.
    for (final kind in ClipKind.values) {
      final rendered = {
        for (final language in AppLanguage.values)
          language: kind.render('{n}', language: language),
      };
      expect(
        rendered.values.toSet(),
        hasLength(AppLanguage.values.length),
        reason: '${kind.fileSuffix} does not differ across all languages',
      );
    }
    for (final line in WakeLine.values) {
      final rendered = {
        for (final language in AppLanguage.values)
          language: line.render('{n}', language: language),
      };
      expect(rendered.values.toSet(), hasLength(AppLanguage.values.length));
    }
    for (final line in FixedLine.values) {
      final rendered = {
        for (final language in AppLanguage.values)
          language: line.render(language: language),
      };
      expect(rendered.values.toSet(), hasLength(AppLanguage.values.length));
    }
  });

  test('tool/build_clip_pack.py speaks the same sentences, in all three', () {
    // The review that prompted this found the two overshoot copies wrapping
    // at different points, which made byte-identity impossible to verify by
    // eye. This is the check that keeps the Python clip factory and the Dart
    // floor honest with each other; if it fails, one of the two moved and
    // the clips no longer match what the app says.
    //
    // IT NOW COVERS HINDI AND MARATHI TOO, which is the whole point of this
    // slice: the Python file has carried all three languages since the pack
    // was cut on 17 Jul, and the Dart side spoke English under every one of
    // them. A per-language check is the only thing that would have caught
    // that, and the only thing that will catch it coming back.
    final source = File('tool/build_clip_pack.py')
        .readAsStringSync()
        .replaceAll(
          // Python's implicit concatenation across lines: join the
          // halves back into the single string it compiles to.
          RegExp(r'"\s*\n\s*"'),
          '',
        );
    for (final language in AppLanguage.values) {
      for (final template in [
        ...ClipKind.values.map((k) => k.render('{n}', language: language)),
        ...WakeLine.values
            .where((k) => k.fileSuffix != null)
            .map((k) => k.render('{n}', language: language)),
        ...FixedLine.values.map((k) => k.render(language: language)),
      ]) {
        expect(
          source.contains('"$template"'),
          isTrue,
          reason:
              'build_clip_pack.py has no ${language.tag} template matching: '
              '"$template"',
        );
      }
    }
  });

  test('the byte-identity check can still fail', () {
    // The guard above passes by finding a string in a file, which is the kind
    // of test that quietly stops testing anything (twice in one evening on
    // 8 Aug, both times a substring match that could no longer fail). A
    // sentence that is NOT in the Python file must be reported missing.
    final source = File('tool/build_clip_pack.py').readAsStringSync();
    expect(source.contains('"Now approaching {n}, probably."'), isFalse);
  });
}
