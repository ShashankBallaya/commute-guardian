import 'dart:io';

import 'package:commute_guardian/services/announcement_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every en-IN template renders its exact approved sentence', () {
    // Pinned to literals on purpose. These sentences are a contract, not an
    // implementation detail: the Sarvam clips were cut from them, so drift
    // here silently demotes every station back to the device TTS floor.
    expect(
      ClipKind.approach.render('Thane'),
      'Now approaching Thane.',
    );
    expect(
      ClipKind.passed.render('Rabale'),
      'You have passed Rabale.',
    );
    expect(
      ClipKind.destination.render('Nerul'),
      'You have arrived at your destination, Nerul.',
    );
    expect(
      ClipKind.overshoot.render('Shahad'),
      'You have passed your stop. It is alright. Please alight here, '
      'at Shahad.',
    );
  });

  test('clip kinds keep the filename fragments the pack was cut with', () {
    expect(
      ClipKind.values.map((k) => k.fileSuffix),
      ['approach', 'passed', 'overshoot', 'destination'],
    );
  });

  test('tool/build_clip_pack.py speaks the same en-IN sentences', () {
    // The review that prompted this found the two overshoot copies wrapping
    // at different points, which made byte-identity impossible to verify by
    // eye. This is the check that keeps the Python clip factory and the Dart
    // floor honest with each other; if it fails, one of the two moved and
    // the clips no longer match what the app says.
    final source =
        File('tool/build_clip_pack.py').readAsStringSync().replaceAll(
              // Python's implicit concatenation across lines: join the
              // halves back into the single string it compiles to.
              RegExp(r'"\s*\n\s*"'),
              '',
            );
    for (final kind in ClipKind.values) {
      final template = kind.render('{n}');
      expect(
        source.contains('"$template"'),
        isTrue,
        reason: 'build_clip_pack.py is missing the ${kind.fileSuffix} '
            'template: "$template"',
      );
    }
  });
}
