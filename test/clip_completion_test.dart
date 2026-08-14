// THE 14 AUG 2026 RIDE IS WHY THIS FILE EXISTS.
//
// Nine station clips of nine were cut inside a second and their sentences were
// never spoken. The rider heard NOTHING at Kalyan, Thakurli, Dombivli, Kopar or
// Diva. The cause was not the clip, the file, the pack, or iOS. It was this:
//
//   audioplayers DECLARES `onPlayerComplete` as Stream<void>, but builds it as
//   `eventStream.where(...)` with no `.map`, so the object at runtime is a
//   Stream<AudioEvent>. `.first` is therefore a runtime Future<AudioEvent>
//   wearing a Future<void> static type, and `Future.timeout` checks its
//   `onTimeout` closure against the RUNTIME type argument.
//
// So `onTimeout: () { ...; return null; }` analyzes clean, compiles clean, and
// throws on the phone. Nothing in this repo could see it: the analyzer believes
// the package's own signature, and no test had ever awaited a real
// onPlayerComplete.
//
// These tests do not touch a device or a plugin. They reproduce the exact type
// shape, so the trap is caught at the desk from now on.

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shape audioplayers hands us: a `Stream<AudioEvent>` behind a
/// `Stream<void>` static type, exactly as `eventStream.where(...)` produces.
Stream<void> completionStreamLikeAudioplayers(
  StreamController<AudioEvent> controller,
) => controller.stream.where(
  (event) => event.eventType == AudioEventType.complete,
);

const _complete = AudioEvent(eventType: AudioEventType.complete);

void main() {
  group('the audioplayers completion type trap', () {
    test(
      'PROOF THE TRAP IS REAL: awaiting .first with a value-returning '
      'onTimeout throws, even though the static type says it cannot',
      () async {
        final controller = StreamController<AudioEvent>();
        addTearDown(controller.close);
        final completed = completionStreamLikeAudioplayers(controller).first
          ..ignore();

        // This is the 13 Aug code, character for character in shape. If a
        // future audioplayers release genuinely maps the stream, this test
        // fails and the comment above can be deleted. Until then it fails on
        // the phone instead, silently, which is what happened.
        //
        // SYNCHRONOUS, and that detail is the whole diagnosis. The cast is
        // checked when `timeout` is CALLED, not when it expires, so the clip
        // died 60 to 1000 ms in (the cost of play() plus getDuration()) rather
        // than at the end of its budget. Then `finally { player.release() }`
        // cut the sound.
        expect(
          () => completed.timeout(
            const Duration(milliseconds: 10),
            onTimeout: () => null,
          ),
          throwsA(
            isA<TypeError>().having(
              (error) => error.toString(),
              'message',
              contains('FutureOr<AudioEvent>'),
            ),
          ),
        );
      },
    );

    test('the .map<void> fix survives a timeout that never completes', () async {
      final controller = StreamController<AudioEvent>();
      addTearDown(controller.close);
      final completed =
          completionStreamLikeAudioplayers(controller).map<void>((_) {}).first
            ..ignore();

      var timedOut = false;
      await completed.timeout(
        const Duration(milliseconds: 10),
        onTimeout: () {
          timedOut = true;
          return null;
        },
      );

      // The point of the whole thing: a missing completion EVENT must not be
      // read as a missing CLIP. It ends quietly and the queue moves on.
      expect(timedOut, isTrue);
    });

    test('the .map<void> fix still completes normally when the event '
        'does arrive', () async {
      final controller = StreamController<AudioEvent>();
      addTearDown(controller.close);
      final completed =
          completionStreamLikeAudioplayers(controller).map<void>((_) {}).first
            ..ignore();

      var timedOut = false;
      controller.add(_complete);
      await completed.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          timedOut = true;
          return null;
        },
      );

      expect(timedOut, isFalse);
    });

    test('non-completion events do not end the wait', () async {
      final controller = StreamController<AudioEvent>();
      addTearDown(controller.close);
      final completed =
          completionStreamLikeAudioplayers(controller).map<void>((_) {}).first
            ..ignore();

      controller.add(
        const AudioEvent(
          eventType: AudioEventType.duration,
          duration: Duration(seconds: 2),
        ),
      );

      var timedOut = false;
      await completed.timeout(
        const Duration(milliseconds: 10),
        onTimeout: () {
          timedOut = true;
          return null;
        },
      );

      expect(timedOut, isTrue);
    });
  });

  group('nowhere disarms the trap by hand', () {
    // The trap was disarmed at three call sites before it was extracted, and
    // three copies of a fix leave it armed at site four. completionOf is now
    // the only way to await a player, so this guard watches ONE SYMBOL rather
    // than a text shape.
    //
    // WHAT IT DOES NOT CATCH, said plainly so the next reader does not trust
    // it further than it goes: someone hand-rolling
    // `player.eventStream.where(...)` rebuilds the same lie under a different
    // name and walks straight past this.

    /// The real predicate. Both the guard and its twin run THIS, so the two
    /// cannot drift apart while the twin keeps passing. That drift is the
    /// repo's recurring guard failure, now six variations deep.
    bool mentionsRawCompletion(String source) => source
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n')
        .contains('onPlayerComplete');

    List<File> audioFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where(
          (file) => !file.path.replaceAll(r'\', '/').endsWith(
            'services/player_completion.dart',
          ),
        )
        .toList();

    test('THE WALK ACTUALLY FINDS THE SOURCE. Without this the guard below '
        'greens on an empty list and proves nothing', () {
      final files = audioFiles();
      expect(files, isNotEmpty);
      expect(
        files.map((file) => file.path.replaceAll(r'\', '/')),
        contains(endsWith('lib/services/pulse_output.dart')),
        reason: 'a known audio file must be inside the walk, or the walk is '
            'looking somewhere else',
      );
    });

    test('NO FILE TOUCHES onPlayerComplete EXCEPT player_completion.dart', () {
      final offenders = [
        for (final file in audioFiles())
          if (mentionsRawCompletion(file.readAsStringSync())) file.path,
      ];
      expect(
        offenders,
        isEmpty,
        reason: 'use completionOf(player); a raw onPlayerComplete is the '
            '14 Aug 2026 bug waiting for its next onTimeout closure',
      );
    });

    test('and that guard can still fail, through the same predicate, on the '
        'exact line it replaced', () {
      expect(
        mentionsRawCompletion(
          'final completed = player.onPlayerComplete.first..ignore();',
        ),
        isTrue,
      );
    });

    test('and it does not fire on a comment that merely mentions the name', () {
      // The fix is discussed in prose in several files. A guard that cannot
      // tell a warning from a use is the substring-guard bug again.
      expect(
        mentionsRawCompletion('// see player_completion: onPlayerComplete'),
        isFalse,
      );
    });
  });
}
