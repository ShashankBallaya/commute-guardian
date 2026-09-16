import 'dart:async';

import 'package:commute_guardian/services/audio_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// THE ANNOUNCER QUEUE, and the two rides that shaped it.
///
/// These are REAL tests, not source guards, and that is why the queue was
/// lifted out of `GeofenceChainService` in the first place. That service
/// builds its own `FlutterTts` inline and cannot be built under the test
/// binding, so every rule decided inside it can only be checked by reading its
/// source back. Every rule in here is checked by running it.
void main() {
  /// A job that does not finish until the test says so, and records the order
  /// jobs actually ran in.
  ({Future<void> Function() body, Completer<void> gate}) held(
    List<String> order,
    String name,
  ) {
    final gate = Completer<void>();
    return (
      body: () async {
        order.add(name);
        await gate.future;
      },
      gate: gate,
    );
  }

  test('jobs run one at a time, in the order they were added', () async {
    final order = <String>[];
    final queue = AudioQueue();
    await Future.wait([
      queue.add(() async => order.add('a')),
      queue.add(() async => order.add('b')),
      queue.add(() async => order.add('c')),
    ]);
    expect(order, ['a', 'b', 'c']);
  });

  test('A SECOND JOB DOES NOT START WHILE THE FIRST IS SPEAKING', () async {
    // The 13 Aug 2026 ride: the welcome at 17:14:04.023 and the origin clip at
    // 17:14:04.033, two voices at once. Both rides that day opened that way.
    final order = <String>[];
    final first = held(order, 'welcome');
    final queue = AudioQueue();
    unawaited(queue.add(first.body));
    unawaited(queue.add(() async => order.add('clip')));
    await Future<void>.delayed(Duration.zero);

    expect(order, ['welcome'], reason: 'the clip started over the welcome');
    first.gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['welcome', 'clip']);
  });

  test('AN URGENT LINE JUMPS EVERY LINE THAT IS WAITING', () async {
    // The 14 Sep 2026 Kalyan ride. A GPS blackout ended with six `passed`
    // catch-up clips decided in one batch, and the wake check-in was decided
    // right behind them, so "your stop is next" spoke about 10 s late, after
    // six clips naming stations the rider had already gone through.
    final order = <String>[];
    final playing = held(order, 'playing');
    final queue = AudioQueue();
    unawaited(queue.add(playing.body));
    for (var i = 1; i <= 6; i++) {
      unawaited(queue.add(() async => order.add('passed$i')));
    }
    unawaited(queue.add(() async => order.add('WAKE'), urgent: true));
    await Future<void>.delayed(Duration.zero);

    playing.gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      order,
      ['playing', 'WAKE', 'passed1', 'passed2', 'passed3', 'passed4',
       'passed5', 'passed6'],
      reason: 'the wake line must be the next thing the rider hears',
    );
  });

  test('BUT IT NEVER CUTS INTO A LINE ALREADY SPEAKING', () async {
    // The cheaper bug is the worse one. Ten seconds of lateness costs the
    // rider an out-of-order sentence; two voices at once costs the rider the
    // sentence itself, and that is what the single queue was built to stop.
    final order = <String>[];
    final playing = held(order, 'playing');
    final queue = AudioQueue();
    unawaited(queue.add(playing.body));
    await Future<void>.delayed(Duration.zero);

    unawaited(queue.add(() async => order.add('WAKE'), urgent: true));
    await Future<void>.delayed(Duration.zero);
    expect(order, ['playing'], reason: 'urgent preempted a live utterance');

    playing.gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['playing', 'WAKE']);
  });

  test('two urgent lines keep their own order', () async {
    // The ladder speaks more than once. A check-in overtaken by the rung
    // behind it would be a new ordering bug wearing the fix's clothes.
    final order = <String>[];
    final playing = held(order, 'playing');
    final queue = AudioQueue();
    unawaited(queue.add(playing.body));
    unawaited(queue.add(() async => order.add('passed')));
    unawaited(queue.add(() async => order.add('checkIn'), urgent: true));
    unawaited(queue.add(() async => order.add('rung'), urgent: true));
    await Future<void>.delayed(Duration.zero);

    playing.gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(order, ['playing', 'checkIn', 'rung', 'passed']);
  });

  test('A FAILED JOB DOES NOT SILENCE THE REST OF THE RIDE', () async {
    // The old future chain carried a `catchError` for exactly this: one
    // rejected future poisoned every announcement queued behind it. A failed
    // clip is not rare, 4 of 14 on the 13 Aug 2026 ride.
    final order = <String>[];
    final logs = <String>[];
    final queue = AudioQueue(onLog: logs.add);
    final failed = queue.add(() async => throw StateError('clip died'));
    final after = queue.add(() async => order.add('next'));
    await Future.wait([failed, after]);

    expect(order, ['next']);
    expect(logs.any((l) => l.contains('queue continues')), isTrue);
  });

  test('a failed job still completes ITS OWN caller', () async {
    // Otherwise the farewell, which awaits its line with an 8 s bound, waits
    // out the bound on every ride that had one bad clip.
    final queue = AudioQueue();
    await expectLater(
      queue.add(() async => throw StateError('nope')),
      completes,
    );
  });

  test('add() returns when THAT line is done, not when the queue empties',
      () async {
    final queue = AudioQueue();
    final slow = Completer<void>();
    var mineDone = false;
    unawaited(queue.add(() async => slow.future));
    final mine = queue.add(() async {}).then((_) => mineDone = true);
    final tail = Completer<void>();
    unawaited(queue.add(() async => tail.future));

    slow.complete();
    await mine;
    expect(mineDone, isTrue);
    expect(queue.isBusy, isTrue, reason: 'the tail job is still running');
    tail.complete();
  });

  test('the queue reports what is waiting and whether it is speaking',
      () async {
    final queue = AudioQueue();
    expect(queue.isBusy, isFalse);
    expect(queue.waiting, 0);

    final gate = Completer<void>();
    unawaited(queue.add(() async => gate.future));
    unawaited(queue.add(() async {}));
    await Future<void>.delayed(Duration.zero);

    expect(queue.isBusy, isTrue);
    expect(queue.waiting, 1, reason: 'the running job is not a waiting one');
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(queue.waiting, 0);
  });
}
