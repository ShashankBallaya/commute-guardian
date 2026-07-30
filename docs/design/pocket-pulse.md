# Pocket Pulse: a third voice that must never matter

Status: DESIGNED, NOT ACCEPTED. Produced 30 Jul 2026 in a Fable session against
`.scratch/pocket-pulse/fable-architecture-prompt.md`. Four decisions are the
owner's and are listed at the end. No code exists.

## The feature, restated as a constraint

A quiet sound at a configurable interval so the rider knows the phone is still
in their pocket. The interval already lives in Settings
(`AppSettings.pulseIntervalSeconds`: null when off, 45 in crowd mode). What is
being designed here is not the chime, it is the chime's RANK: the pulse is the
least important sound this app makes, sharing a session with the most important
one, and every choice below exists to keep it from ever mattering more than
that.

## Designed twice, plus one killed on sight

**Shape A, a sibling engine on the existing tick.** `PocketPulse`, pure Dart, in
the exact shape of `RideProgress` / `WakeEscalation` / `WindDown`: time passed
in, actions out. It consumes the service's EXISTING 5-second `onRepeatEvent`
tick (`ForegroundTaskEventAction.repeat(5000)`, which already drives the other
engines) and emits `PulseChime` actions that the shell plays.

**Shape B, an AudioDirector.** One component owning ALL audio: a priority queue
where announcements, ladder tone, wind-down lines and pulses are producers and
the director alone touches the session. Strictly deeper as a module, and it is
the shape this codebase grows toward if a FOURTH voice ever arrives. Rejected
NOW for one reason: it restructures `geofence_chain_service.dart`, and that file
is under the riverpod migration's additive-only rule while the verification ride
is owed. The precedence table below IS the director's contract, enforced today
by three booleans instead of a queue. If a fourth voice arrives, build B and
fold this engine into it.

**Shape C, a UI-isolate timer. Killed on sight.** The 30 Jul swipe bench proved
the UI dies while the ride lives. A pulse that silently stops when the UI dies
is not a degraded feature, it is a FALSE ALARM: the reassurance stopping is
exactly the signal the rider installed the app to never get wrongly. The pulse
lives where the ride lives or it lies.

**Verdict: A.** The deletion test passes: delete `PocketPulse` and its timer
state, suppression rules and cadence anchoring all regrow ad hoc inside the
chain service, which is where they must not live.

## 1. The engine

`lib/services/pocket_pulse.dart`. Pure Dart, no plugin imports, no Riverpod.

```dart
sealed class PulseAction {}
/// Play the chime (and vibrate, if the rider chose that).
class PulseChime extends PulseAction {}
/// A diagnostic for the ride log, never spoken. Same lesson as WindDownNote:
/// silence has no cause in a log, and a pulse that stopped firing must say why.
class PulseNote extends PulseAction { final String reason; }

class PocketPulse {
  PocketPulse({int? intervalS});

  /// Start, stop or retime, including MID-RIDE. Re-anchors: the next chime is
  /// interval from NOW, because a rider flipping crowd mode on wants the new
  /// cadence immediately, not after the old one drains.
  void setInterval(int? seconds, DateTime now);

  /// Suppression inputs, as mutators, matching how WakeEscalation is fed.
  void onWakeLadder(bool live, DateTime now);
  void onCallState(bool inCall, DateTime now);

  /// The 5 s service tick. `announcerBusy` is the shell's `_speaking` /
  /// clip-queue state, passed per tick because it is genuinely a per-tick
  /// fact about the world, not engine state.
  List<PulseAction> onTick(DateTime now, {required bool announcerBusy});
}
```

State inside: the interval, `_nextDueAt` (anchored cadence: advanced by whole
intervals from the schedule, so a deferred chime never shifts the next one),
`_deferredSince`, and the two suppression flags. Nothing else.

Cadence rules:

- **First chime at start + interval**, never at start. The welcome line owns the
  start, and a rider who just pocketed the phone needs no reassurance yet.
- **Deferral** (announcer busy): retry each tick, cap 60 s, then skip the slot.
  If a deferral crosses the next slot, they collapse to one chime, never two.
- **Drop** (ladder live, or in a call): the slot is simply lost. On stand-down
  or call end, the next chime is the next SCHEDULED one, not an immediate
  catch-up: a rider who just acknowledged an alarm or hung up a call has the
  phone in their hand and needs no pocket reassurance for it.
- `PulseNote` is emitted on suppression TRANSITIONS only ("pulses suppressed:
  ladder live", "pulses resumed"), never per skipped slot, so a crowd-mode ride
  cannot spam the log.

## 2. Where the timer lives

Nowhere new. The engine is a field of `GeofenceChainService`, built at ride
start and fed by the `onTick` the service already receives every 5 seconds.
**No new timer, no alarm, no wakelock, no scheduler.**

Consequences, case by case:

- Screen locked / app backgrounded: the tick is the same one that survived
  Phase 0's 90-minute locked-screen proof. Pulses continue.
- App swiped out of recents: the 30 Jul bench proved the service survives.
  Pulses continue, which is CORRECT and is the scenario the feature exists for.
- Service killed and restarted: the engine is rebuilt from the store (see 4)
  and re-anchors at restart + interval. A missing chime during the restart gap
  is accepted.
- Ride ends, any path: the engine dies with the chain in the same teardown that
  silences announcements. The pulse CANNOT outlive the ride, structurally,
  which is the answer to the worst failure mode before it is even listed.

**Ride-only, and argued rather than assumed.** Outside a ride there is no
foreground service, so an outside-ride pulse means background timers, exact
alarms or a persistent service on a phone that is not travelling: a different
permissions story, a real battery bill, and a Play Store justification burden,
for a question ("is my phone in my pocket") that outside a commute the rider
answers by having a normal day. CLAUDE.md itself scopes the pulse inside Travel
Mode, and the anti-theft deferral note already parks the outside-ride sibling
in v2 where it belongs.

## 3. The audio contract

**What the pulse asks for: a transient duck, the same shape as an
announcement, held for well under a second.** `AndroidUsageType
.assistanceSonification` with `gainTransientMayDuck`; on iOS it plays inside
the announcement-shaped session that already ducks. The brief dip in the
rider's music is not a cost, it is PART OF THE SIGNAL: in a loud carriage a
quiet chime can be masked, but the dip is felt even then.

What it deliberately does NOT do:

- **Never the alarm stream, never focus-free piercing.** That is the wake
  tone's rank (`wake_alert_output.dart` asks for NO focus and rides the alarm
  stream so it pierces). The pulse taking the same rank would make the two
  indistinguishable in the one place they must never be confused: the rider's
  ear.
- **Never through the TTS queue or the clip queue.** It is not speech. It gets
  its own small player with `ReleaseMode.release`, played once, no loop mode
  anywhere near it.
- **It MUST stamp `SelfAudioInterruptionFilter.noteOwnAudioStarted`.** This is
  the one integration that is invisible until it fires: our own audio starting
  can raise an interruption, interruptions are fed to the wake engine as "the
  rider took a call, they are awake", and on 21 Jul that chain STOOD THE LADDER
  DOWN. A pulse that does not stamp the filter reintroduces that bug through
  the back door at whatever interval the rider chose.

The precedence table:

| Pulse vs | Rule | Why |
|---|---|---|
| Wake ladder | **Dropped**, entirely, for as long as the ladder is live | The alarm is the product. Also: on iOS the ladder may hold a seized or ducked session (`CannotInterruptOthers`, 24 Jul), and ANY sibling play against that session is how the tone loop has died before. The pulse does not negotiate here, it vanishes. |
| Announcement / clip | **Deferred** ≤ 60 s, then the slot is skipped | A chime mid-sentence truncates neither cleanly. The shell already knows it is speaking (`_speaking`, clip queue); the engine waits. |
| Wind-down countdown | **Continues** | The rider is walking through a crowd with the phone pocketed. That is not a reason to stop; the teardown will stop it. |
| Phone call | **Dropped** until the call ends | The handover's own rule for announcements ("never interrupt calls") applied down-rank. Call state arrives the same way the wake engine gets it. |
| Rider's music | **Transient may-duck**, sub-second | The dip is the fallback signal when the chime is masked. |

## 4. How the interval crosses the isolate boundary

Settings are written to `AppFlags`, which is DRIFT, which the service isolate
never opens (corrected fact in `riverpod-adoption.md`). So the interval crosses
the same way the Sarvam flags do, plus one live hop:

- **At ride start**: the UI writes `pulse_interval_s` and `pulse_vibrate` to
  `FlutterForegroundTask.saveData`, next to the Sarvam flags. The service reads
  them in `onStart`. The STORE is what a restarted service reads, which is what
  makes the restart case in section 2 work.
- **Mid-ride**: the UI sends `pulse_set:<seconds|off>` via `sendDataToTask`
  (the handler grows one case, additive), AND rewrites the store key in the
  same breath. Dual-write, deliberately: a message updates the running engine,
  the store survives a restart, and missing either half creates a ride that
  ends on a different interval than it shows.
- Settings changed with no ride running: nothing to send; the store is written
  at the next start.

## 5. What the pulse sounds like

- **One bundled asset**, `assets/audio/pulse_chime.wav`, 400 to 600 ms, a soft
  two-note figure, ending clean with no tail. Bundled, not synthesised: a
  generated tone cannot be replaced by a nicer one without a code change, and
  the Plus tier sells chime CHOICE later, which is asset variants through this
  same path. Not a clip-pack member: it is not language content and must exist
  on the device-TTS floor.
- Played at the rider's media volume, deliberately. The pulse is a media-rank
  sound; if their music is quiet, the pulse is quiet.
- **Vibration**, if `vibrateWithPulse` is on: one short buzz, ~100 ms, Android
  only, a pattern deliberately nothing like the wake pattern's long triple. The
  wrist must never confuse the two.
- The engine emits `PulseChime`; a small `PulseOutput` (the `WakeAlertOutput`
  shape: decides nothing, does what it is told) plays and buzzes.

## 6. Failure modes accepted, as the rider experiences them

1. **A chime skipped under a busy minute** (announcement deferral overruns):
   silence for up to two intervals. Accepted; the alternative is a queue, which
   is state that can leak chimes late.
2. **The restart gap**: a service restart mid-ride re-anchors the cadence and
   one slot may vanish. Invisible in practice.
3. **A masked chime in a loud carriage**: the duck dip is the remaining signal.
   If bench 1 shows the dip is ALSO imperceptible on cheap earphones, the chime
   gets louder, not the rank higher.
4. **The worst one, a pulse that keeps firing when it should not**: made
   structural rather than behavioural. It cannot outlive the ride (engine dies
   in the chain teardown), cannot loop (release mode, one-shot player), cannot
   fire over the alarm (dropped while ladder live), cannot fire into a call.
   The residual case is a lost `pulse_set:off` mid-ride, and the dual-write
   plus an in-process message channel leaves no realistic path to it.
5. **A pulse-caused interruption read as a call**: prevented by the filter
   stamp in section 3, and bench 2 exists to prove the stamp works rather than
   trust it.

## 7. The bench, before any build, one hour at the desk

Add one temporary `test_pulse` trigger (the `test_tts` pattern, one line in the
handler). Then, in order:

1. **The duck, by ear.** Music playing (Spotify and YT Music), chime at 45 s
   cadence, wired and Bluetooth: is the dip acceptable at song volume, and is
   the chime audible over loud music? This answers decision 4 with ears rather
   than opinions.
2. **The filter stamp.** Fire the chime ~150 ms after a TTS line starts (the
   21 Jul collision window reproduced on demand): confirm the interruption is
   attributed to our own audio and the ladder does NOT stand down.
3. **Against a live ladder, deliberately unsuppressed.** Desk-repro the iOS
   ducked-alarm state (the 24 Jul repro is on demand) and fire a chime at it:
   document what breaks, so the suppression rule has evidence rather than
   folklore.
4. **Cadence under lock.** Crowd mode, screen locked, 30 minutes: does the 45 s
   cadence hold through Doze on the 3T, and what is the battery delta against
   the same 30 minutes without pulses?
5. **The speaker question.** No earphones, packed-train volume: how obnoxious is
   it really? This answers decision 2 with a fact.

Numbers that are bench-tunable and must not become folklore: the 60 s deferral
cap, the chime length, the vibrate duration. The INTERVALS are product values
from Settings and are not tunable here. Nothing in this design needs ride-log
tuning: the pulse is clock-driven, not geometry-driven, which is exactly why it
can be desk-benched in an hour.

## Battery, priced

Zero new wakeups: the engine rides a tick that already fires. The marginal cost
is the audio path itself: at 3 minutes over a 90-minute ride, 30 chimes at
~0.5 s each, ~15 s of audio hardware; crowd mode, 120 chimes, ~60 s. Both are
noise against the GPS stream that dominates the existing 9 to 10 percent per
hour. Bench 4 turns this claim into a measurement.

## The four decisions that are the owner's

1. **Ride-only in v1.** Recommended yes; the outside-ride sibling is the v2
   anti-theft adjacency, where its permissions and battery story belong.
2. **No earphones connected: skip or play on speaker?** Recommendation: SKIP,
   with a `PulseNote` so the log says why. The feature's own Settings copy
   says "through your earphones", and a chime from a pocket speaker on a
   packed train is a nuisance that also advertises the phone. Uses
   `AudioOutputGateway`, failing open (if detection is unavailable, play).
   Bench 5 informs this.
3. **The ladder drops pulses entirely** (never queues, never plays quietly
   underneath). Recommended yes; the iOS seized-session evidence makes this
   close to forced.
4. **The chime's rank: transient may-duck** rather than focus-free mixing.
   Recommended as designed, but ratify AFTER bench 1, with ears.
