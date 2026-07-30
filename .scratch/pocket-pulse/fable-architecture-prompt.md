# Prompt for Fable: architect Pocket Pulse

Paste the block below into a Fable session opened in `C:\dev\commute-guardian`.

Fable is being asked to ARCHITECT, not to implement. The output is a design with
its trade-offs argued, not a pull request. The build follows from it.

Why this one wants an architecture pass at all: Pocket Pulse is periodic
background audio sharing one audio session with the announcement engine and the
wake alarm, and that session has produced every hard bug this project has had.

---

You are architecting one feature of a Flutter commuter-rail app, Commute
Guardian. Read `CLAUDE.md`, `CONTEXT.md`, `docs/design/riverpod-adoption.md` and
`docs/design/ride-snapshot.md` first. Do not write production code in this
session. Produce a design and argue its trade-offs.

## The feature

**Pocket Pulse**: a quiet sound through the rider's earphones at a configurable
interval, so they know their phone is still in their pocket without taking it
out. It is half the product per `CLAUDE.md` and it currently has ZERO lines of
code.

It is FREE at its default interval. Guardian Plus sells the interval choice, the
chime, and the duration. Settings (Screen 6, built) already stores all of it:
see `lib/models/app_settings.dart` and `lib/state/settings_providers.dart`.
`AppSettings.pulseIntervalSeconds` is the single derived answer, null when off,
45 when crowd mode is on.

## The constraints, which are not negotiable

**THE AUDIO SESSION IS THE WHOLE PROBLEM.** Every hard bug in this project has
lived here, and Pocket Pulse adds a periodic third voice to it:

- The wake alarm escalates through `[0.3, 0.6, 1.0]` and must NEVER be quietened,
  delayed, masked or pre-empted by a pulse. This is the one thing the product
  exists to do.
- On iOS the alarm sometimes cannot seize the session and is forced into a
  ducked one (`CannotInterruptOthers`, benched 24 Jul). Read
  `lib/services/self_audio_interruption.dart` and `wake_alert_output.dart`.
- Station announcements duck the rider's music through `audio_session`. A pulse
  landing mid-announcement must not truncate it or be truncated confusingly.
- The rider is usually playing their own music. A pulse is not worth a full duck
  of someone's song every three minutes; work out what it IS worth.

**Two isolates.** The ride runs in an Android foreground-service isolate with its
own heap (`lib/foreground/geofence_task_handler.dart`); the UI runs in the main
isolate. They share only `sendDataToMain` / `sendDataToTask` messages and a
key-value store. Settings are written in the UI isolate. Decide where the pulse
timer lives and how the interval reaches it, and note that the Sarvam bench flags
are the existing precedent for a setting crossing that boundary at ride start.

**No backend. Everything on-device.**

**Battery.** Screen 4's own budget note puts the app at 9 to 10 percent an hour,
already over the handover's target. A timer firing every 2 to 10 minutes for 90
minutes, waking the CPU and the audio hardware, has a real cost. Phase 0's
battery result was hard won and must not be quietly spent.

**When does it run?** Decide and argue it: only during a ride, or also outside
one? "Is my phone in my pocket" is not obviously a ride-only question, but a
background timer outside a ride is a different permissions and battery story
entirely.

## What to produce

1. The engine: its interface, its state, and what it emits. Pure Dart, no plugin
   imports, in the shape of `RideProgress`, `WakeEscalation` and `WindDown`,
   which all take time as a parameter and return actions as data. Time must be
   injectable or it cannot be replayed.
2. Where the timer actually lives, and what happens to it when the app is
   backgrounded, the screen locks, the app is swiped out of recents (the 30 Jul
   bench showed the service survives that), and the process dies.
3. The audio contract: exactly what the pulse asks the session for, and what it
   does when it cannot have it. A precedence table covering pulse against
   announcement, against wake ladder, against wind-down, against a phone call.
4. How the rider's interval reaches the engine, given settings are written in the
   other isolate, including what happens when it is changed MID-RIDE.
5. What the pulse sounds like, at a level of detail an implementer can act on:
   duration, whether it ducks or mixes, and whether it is a bundled asset or
   synthesised.
6. The failure modes you are accepting, and how each one looks to a rider on a
   train. Be specific about the worst one: a pulse that keeps firing when it
   should have stopped, in someone's ear, on a packed train.
7. What to BENCH before building, at the desk, in an hour. There is a standing
   decision that the audio risk gets spiked early rather than on the last
   evening, and it has slipped twice.

## How to argue it

Use the `/codebase-design` vocabulary: a deep module with a narrow interface
beats a wide one. Design it twice and compare with `/design-an-interface` rather
than presenting the first workable shape as inevitable.

Be concrete about this repo: name the files and the existing types. Where a
locked decision is in your way, say so explicitly and make the case rather than
quietly designing around it.

One warning drawn from this project's own history: the wake ladder's rung timings
and the wind-down's thresholds were both tuned against REAL RIDE LOGS, and there
are six of them plus a replay tool (`tool/replay_ride.dart`). If any number in
your design wants to be tuned that way, say which and against what, rather than
inventing a constant that then becomes folklore.
