import 'dart:async';

/// ONE QUEUE FOR EVERYTHING A RIDE SAYS, clips and speech alike, and the one
/// place a line may overtake another.
///
/// THE QUEUE EXISTS BECAUSE OF THE 13 AUG 2026 RIDE. The welcome began at
/// 17:14:04.023 and the origin's clip at 17:14:04.033, ten milliseconds later,
/// two voices at once in the rider's earphones. Clips and speech ran on two
/// separate chains. Merging them buys the obvious guarantee: nothing the app
/// says can start until the last thing it said has finished.
///
/// THE PRIORITY EXISTS BECAUSE OF THE 14 SEP 2026 KALYAN RIDE. An eleven
/// minute GPS blackout ended with six `passed` catch-up clips decided in one
/// batch, and the wake check-in ("your stop is next") was decided right behind
/// them. It spoke about 10 s late, after six clips naming stations the rider
/// had already gone through.
///
/// WHAT THAT RIDE DID NOT COST, because the claim keeps coming back: the alarm
/// TONE was never delayed. The tone does not come through here at all. The
/// 26 s read off that log is `WakeEscalation.checkInToFirstRung`, 25 s by
/// design, and the same gap appears at Kalwa earlier in the same ride with no
/// catch-up queue present.
///
/// IT IS A PLAIN CLASS WITH NO PLUGINS IN IT so that the ordering rules have
/// REAL tests rather than source guards. `GeofenceChainService` cannot be
/// built under the test binding, so anything decided inside it can only be
/// checked by reading its source back. This can be checked by running it.
class AudioQueue {
  AudioQueue({this.onLog});

  /// Where the queue says what it did. Optional, because the queue must run in
  /// a test with no ride behind it.
  final void Function(String message)? onLog;

  /// Decided and not yet started. The running job is NOT in here.
  final List<_AudioJob> _waiting = <_AudioJob>[];

  bool _busy = false;

  /// Whether a job is running right now.
  bool get isBusy => _busy;

  /// How many jobs are decided and still waiting their turn.
  int get waiting => _waiting.length;

  /// Queues one piece of audio work and returns a future that completes when
  /// THAT work is done, not when the queue has emptied.
  ///
  /// `urgent` inserts it ahead of everything still waiting, behind any urgent
  /// job already waiting (so two ladder lines keep their own order), and
  /// NEVER ahead of the job now running. Cutting into a line already speaking
  /// is the 13 Aug 2026 bug, and two voices at once costs the rider more than
  /// ten seconds of lateness does.
  Future<void> add(Future<void> Function() body, {bool urgent = false}) {
    final job = _AudioJob(body, urgent: urgent);
    if (urgent) {
      var at = 0;
      while (at < _waiting.length && _waiting[at].urgent) {
        at++;
      }
      final jumped = _waiting.length - at;
      _waiting.insert(at, job);
      if (jumped > 0) onLog?.call('AUDIO urgent line jumps $jumped queued.');
    } else {
      _waiting.add(job);
    }
    unawaited(_pump());
    return job.done.future;
  }

  /// Runs the queue, ONE JOB AT A TIME, for as long as there is one.
  ///
  /// Errors are swallowed for the reason the old future chain carried a
  /// `catchError`: a rejected future poisoned every announcement queued behind
  /// it, which silences the rest of the ride one line at a time. A job that
  /// throws still completes its own waiter, or the caller waits for ever.
  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_waiting.isNotEmpty) {
        final job = _waiting.removeAt(0);
        try {
          await job.run();
        } catch (error) {
          onLog?.call('AUDIO job failed, queue continues: $error');
        } finally {
          if (!job.done.isCompleted) job.done.complete();
        }
      }
    } finally {
      _busy = false;
    }
  }
}

/// One piece of audio work waiting its turn.
///
/// A class rather than a record because [done] is created with the job and
/// completed by whoever runs it, which is the whole point: the caller gets a
/// future for ITS OWN line, not for the queue emptying.
class _AudioJob {
  _AudioJob(this.run, {required this.urgent});

  /// The work itself. It runs alone: the pump awaits it before starting
  /// anything else.
  final Future<void> Function() run;

  /// Whether this may overtake work that is queued but not started.
  final bool urgent;

  /// Completed when [run] returns, however it returns.
  final Completer<void> done = Completer<void>();
}
