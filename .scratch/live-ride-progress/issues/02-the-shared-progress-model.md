# 02 - What is the shared progress model?

Type: grilling
Status: resolved
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

## Answer

Resolved 30 Jul 2026. The owner accepted all four decisions as designed.

**The model is `RideSnapshot`**, a pure Dart class in `lib/models/ride_snapshot.dart`,
built by one factory over the primitives that already cross the isolate seam:
origin and destination ids, `reachedIndex`, `destinationReached`, `wakeLadderLive`,
`windDownLive`. It derives `lastReached`, `next`, the between-pair,
`stationsRemaining`, `nextInterchange` and `phase`. It holds no ETA, no
interpolated position, and no copy strings.

**Nothing new is persisted.** The snapshot is never stored, only its inputs are,
and those already survive process death. That is what makes recreation a non-event
here for the same structural reason it already is for `LiveRide`.

The four decisions, all ACCEPTED:

1. **Shape A over shape B.** A shared pure projection, both isolates calling the
   same function, rather than the service serializing a blob and shipping it.
   B failed the deletion test and would have reversed "journeys cross the bridge
   as IDS, never as objects".
2. **Alerts are overlay flags, not phases.** A ladder can be live during
   `approach` or `arrived`, and the notification's actions are already composed
   from both flags. Phase drives narrative, flags drive overlays.
3. **Copy is formatted in Dart** and shipped to SwiftUI as pre-formatted strings,
   so the Live Activity is a dumb layout and phrasing lives in one place beside
   the Android formatter.
4. **`_updateSurface()` unifies notification text and buttons** into a single
   `updateService` call, so the "does an absent parameter clear or keep" question
   never has to be answered in production.

Phase precedence: `windingDown` > `arrived` > `approach` > `active` > `locating`.

Full design, including the shape comparison, the isolate argument, the iOS seam
and all six accepted failure modes: `docs/design/ride-snapshot.md`.

**What it also bought.** A third shape was killed on sight, rendering the
notification from the UI isolate, which the 30 Jul swipe bench proved would freeze
the surface exactly when the rider is asleep with the phone pocketed. That rules
out `flutter_local_notifications`-from-a-widget permanently. And the design caught
a latent clobber risk in `_updateNotificationButtons()`, shipped that same morning
in `91d52c8`; decision 4 removes it by construction, and ticket 04 still confirms
the underlying plugin behaviour.

**Carried forward, not resolved here.** The `approach` window contradicts the
`WakeChoice` toggle for riders who chose "Only destination". That is now ticket 10.
The claim that iOS runs the plugin's task in the main isolate went to ticket 03.
