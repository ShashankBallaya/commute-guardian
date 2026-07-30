# 02 - What is the shared progress model?

Type: grilling
Status: claimed
Blocked by: none

## Question

The spine of the map. Everything else renders this.

Uber, Zomato and Blinkit all ship one progress model rendered twice. Define ours,
once, as data and state transitions, with no reference to either platform's
widgets. If this is right, the Android notification, the iOS Live Activity and
Screen 4 are three views of one thing. If it is wrong, they will drift and
disagree, which is the failure mode this project has already paid for once
(the "one projector, never two" rule that produced `RideProgress`).

To settle:

- **Fields.** Which two stations the rider is between, the last confirmed station,
  the next station, stations remaining, destination, and terminal state. Which of
  these are derived rather than stored, and from what.
- **The between-stations problem.** Geofences fire on ENTER at a station. Between
  two fences the app knows the last one it passed but not where it is on the
  segment. Does the surface say "between Thane and Mulund" (honest, coarse) or
  interpolate a position (prettier, invented)? The project's standing bias is that
  a surface must not claim more than the data supports.
- **States.** At minimum: preparing, running, approaching, alert live, arrived,
  winding down, ended. Which of these the passive surface distinguishes, and which
  collapse.
- **Where it lives.** `RideProgress` already exists in the service isolate and is
  the single projector. `LiveRide` in `lib/state/ride_providers.dart` is its
  store-backed UI-side projection. Does the passive surface read one of these, or
  does it need a third thing? A third thing needs justifying.
- **Update cadence.** Once per station is roughly 30 updates on a Shahad to Andheri
  ride. Whether anything updates more often than that, and what.

Consult `/domain-modeling`. The ubiquitous language matters here: Journey vs Ride
is already a settled distinction in `CONTEXT.md` and this model must not blur it.

## Progress, 30 Jul 2026

A Fable session designed this against the prompt in
`../fable-architecture-prompt.md`. The full design is written up at
`docs/design/ride-snapshot.md`.

Summary: a pure `RideSnapshot` in `lib/models/ride_snapshot.dart`, built by one
factory over the primitives that ALREADY cross the isolate seam (ids,
`reachedIndex`, `destinationReached`, and the two alert flags). Nothing new is
persisted. Both isolates call the same pure function, so the snapshot is a
projection OF `RideProgress`'s output rather than a second projector. Screen 4
takes a snapshot and gives up its own `_stationsRemaining` derivation. iOS attaches
at a `LiveActivityGateway` in the main isolate, so a "no" from ticket 03 costs that
gateway and nothing else.

Two shapes were compared and a third killed on sight (a UI-isolate renderer, dead
because the 30 Jul bench proved the UI dies while the ride lives). The design also
caught a live risk in code shipped that morning: `_updateNotificationButtons()`
calls `updateService` with buttons and no text, so if the plugin treats an absent
parameter as "clear", adding text updates would wipe the "I'm awake" button off a
sounding alarm. Fix is to unify both into one `_updateSurface()` call.

## STILL OPEN. Do not resolve this ticket yet.

Four decisions are the owner's and are unanswered:

1. Shape A (shared pure projection) over shape B (service ships a blob).
2. Alert as an overlay flag rather than a phase.
3. Copy formatted in Dart and shipped to SwiftUI as strings.
4. The `_updateSurface()` unification of notification text and buttons.

Two review caveats also unresolved, both written up in the design doc: the
`approach` phase window contradicts the `WakeChoice` toggle for riders who picked
"Only destination", and the claim that iOS runs the plugin's task in the main
isolate is asserted rather than verified (now added to ticket 03).
