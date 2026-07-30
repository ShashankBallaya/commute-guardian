# RideSnapshot: one progress model, three renderings

Status: DESIGNED, NOT ACCEPTED. Produced 30 Jul 2026 in a Fable session against
`.scratch/live-ride-progress/issues/02-the-shared-progress-model.md`. Four
decisions are still the owner's and are listed at the end. No code exists.

## The problem

Live ride progress must appear on surfaces the rider reads WITHOUT opening the
app: an updating ongoing notification on Android, later a Live Activity on iOS.
Screen 4 already shows the same facts in-app. Three renderings, and they must not
be able to disagree.

## Designed twice, plus one killed on sight

**Shape A, shared pure projection.** A pure `RideSnapshot` built by one factory
over the primitives that already cross the isolate seam. Both isolates call the
same function on the same inputs; three renderings are three call sites.

**Shape B, service computes and ships.** The service isolate builds the snapshot
and its display strings, saves a serialized blob under one key and sends the same
blob to main. UI and Live Activity deserialize and display. One computation, zero
skew.

**Shape C, UI-isolate rendering. Killed on sight.** The main isolate renders the
notification. Dead on arrival: the 30 Jul swipe bench proved the UI dies while the
ride lives, so the notification would freeze exactly when the rider is asleep with
the phone pocketed. The Android notification MUST be written from the service
isolate. This also permanently rules out any `flutter_local_notifications`
-from-a-widget shape, which is what most people reach for first.

### The comparison

| | A: shared projection | B: ship the blob |
|---|---|---|
| Interface at the seam | unchanged: ids, `reachedIndex`, two flags | a new versioned serialized object |
| Depth | one factory hides -1 handling, clamping, phase precedence, interchange adjacency | wire object restates what three primitives already imply: shallow |
| Locality | phase precedence in one file | precedence in the service, PARSING of it in two other places |
| Skew | transient, self-healing, same as Screen 4 today | none |
| Deletion test | delete it and every renderer regrows its own derivation (the pre-30-Jul world) | delete it and you recompute from ids + index, i.e. you get A |
| House precedent | "Journeys cross the bridge as IDS, never as objects. Two isolates, one planner, zero serialization" | reverses a decision `riverpod-adoption.md` argued explicitly |

B fails the deletion test: its blob is a pass-through of derivable state, a large
interface over no behaviour. B also bifurcates anyway, because Screen 4's chain
list needs the whole `Journey`, which you would not ship per update, so Screen 4
keeps deriving locally while the notification reads the blob. Two paths again,
which is the disease this design exists to cure.

**Verdict: A**, with one idea stolen from B at the iOS seam: ship PRE-FORMATTED
STRINGS to SwiftUI so copy lives in Dart.

## 1. The model

`RideSnapshot`, in `lib/models/ride_snapshot.dart`. Pure Dart, no Riverpod, no
plugin imports, same discipline as the engines.

**Stored inputs, all existing, all primitives.** `originId` and `destinationId`
(from which each isolate replans its own `Journey`: deterministic planner, house
pattern), `reachedIndex` (-1 sentinel), `destinationReached`, `wakeLadderLive`,
`windDownLive`. NOTHING NEW IS PERSISTED. That sentence is the design.

**Derived by the factory.** `lastReached` (null before localization), `next` (null
at destination), the between-pair those two make, `stationsRemaining` (the exact
expression currently open-coded at `travel_mode_screen.dart:67`, which moves in
here and dies there), `nextInterchange` (from `Journey.interchanges`; whether any
rendering shows it is ticket 06's call), and `phase`.

**Phase, with explicit precedence.** This is the hidden complexity that earns the
module its depth:

    windingDown > arrived > approach > active > locating

`locating` is `reachedIndex < 0`. `approach` is the last-stations window (see the
open caveat below, which disputes how that window is defined).

`wakeLadderLive` is deliberately NOT a phase. It is an overlay flag carried on the
snapshot, because a ladder can be live during `approach` or `arrived`, and the
notification's ACTIONS are already composed from the two flags (commit
`91d52c8`). Phase drives narrative; flags drive overlays. Names reuse the
handover's state vocabulary rather than coining new ones.

**Not in the model.** ETA (Phase 3; `etaLine` on Screen 4 stays the seam, and the
snapshot must not duplicate a seam). Interpolated position between stations
(ENTER-only geofences cannot support it; the surface says "between X and Y" and
nothing finer). Copy strings (facts in the model, phrasing in the renderers, with
one shared formatter for the two passive surfaces so they cannot phrase-drift).

## 2. Where it lives: the same pure function, in both isolates

`RideProgress` remains the only PROJECTOR: the one thing that turns fixes into
`reachedIndex`. `RideSnapshot` is not a second projector; it is a projection OF
the projector's output, deterministic over it. Two call sites of one function
cannot disagree any more than two calls to `JourneyPlanner.plan` disagree today,
and that is the identical trust the codebase already extends to the planner. This
is the argument that satisfies the "one projector, never two" rule rather than
fighting it.

Service side, one concrete consequence: `GeofenceChainService` owns the journey
and the flags, so it gains an additive `RideSnapshot snapshot()` (or the callbacks
carry one). The handler's `_updateNotificationButtons()` from 30 Jul grows into
`_updateSurface()`: ONE CALL SITE THAT ALWAYS PASSES `notificationText` AND
`notificationButtons` TOGETHER IN A SINGLE `updateService` CALL.

That matters now, not later. `_updateNotificationButtons()` currently calls
`updateService` with buttons and no text. If the plugin treats an absent parameter
as "clear" rather than "keep", then the moment anyone adds text updates, a station
crossing wipes the "I'm awake" button off a sounding alarm: precisely the defect
fixed on 30 Jul, re-entering through the back door. One function owning the whole
notification makes the question moot instead of answering it.

## 3. Screen 4

The header's derivations (`_stationsRemaining`, destination name) move into the
snapshot; `TravelModeScreen` takes a `RideSnapshot` instead of the loose pair. The
chain card keeps rendering `journey.chain` against `reachedIndex`, both read off
the snapshot object, because forcing thirty list rows through model fields would
bloat the interface for zero behaviour: the list is presentation of a derivable
`Journey`. One source object, renderer-owned layout.

A `rideSnapshotProvider` (a one-line derivation over `liveRideProvider`,
`rideAlertsProvider` and the replanned journey) is UI-side wiring, inside the
spirit of the provider budget.

## 4. What crosses the isolate boundary

Nothing new. Ids at start; `reachedIndex` per station, roughly 30 times on a
Shahad to Andheri ride; flag transitions, a handful; `destinationReached` once.
The snapshot never crosses; its inputs already do. Cadence for every rendering is
per-station plus transitions, never per-fix.

## 5. What survives process death

Everything, because the snapshot is never stored, only its inputs are, and they
already survive (the `LiveRide` invariant, extended to the flags by `91d52c8`).

- UI death: recompute on rebuild. Proven twice.
- Service death and restart: the restarted `RideProgress` re-localizes at -1 by
  design, so the surface honestly shows `locating` until the next usable fix,
  rather than trusting a stale index.

## 6. The iOS seam

A `LiveActivityGateway` in the main isolate, mirroring the `AudioOutputGateway`
discipline: one door, failing open, logging failures without touching the ride. It
watches `rideSnapshotProvider` and pushes start/update/end over a channel with a
ContentState of pre-formatted strings plus raw numbers, so SwiftUI stays a dumb
layout and copy lives in Dart, one place, next to the Android formatter.

If ticket 03 returns "backgrounded local updates are impossible", the casualty
list is exactly this gateway: model, Android and Screen 4 untouched.

## 7. Failure modes accepted, as the rider sees them

1. **Honest lag.** "Between Mumbra and Diva" persists until Diva's fence fires.
   Never interpolated.
2. **Transient skew.** Notification and Screen 4 may differ for about a second
   after a station. Same inputs, different arrival times, self-healing.
3. **Missed fence.** The surface jumps two stations at once when the backstop
   catches up, same as the audio does today. Correct late rather than wrong early.
4. **OEM update throttling.** Every update renders ABSOLUTE state, never deltas,
   so any dropped update is fully repaired by the next one. Standing design rule
   for all renderers.
5. **Service restart mid-ride.** A brief `locating` on the surface. True, and
   preferable to a confident stale claim.
6. **Overshoot.** No dedicated passive narrative in v1; audio carries it, flags
   carry the rest. Ticket 05's territory if that is wrong.

## Review caveats, raised 30 Jul and NOT resolved

**1. The `approach` window is wrong for half the riders.** The design defines
`approach` as "2 or fewer stations remaining, matching the wake ladder's window".
That window is not fixed: it is Screen 4's `WakeChoice` toggle, `lastTwoStations`
or `onlyDestination`. A rider who chose "Only destination" would get a surface
announcing an approach the ladder is not going to act on. `phase` must read the
rider's actual choice, or `approach` must be defined without reference to the
ladder at all.

Worth noticing: this would make the passive surface the FIRST ACTUAL CONSUMER of
that toggle, which has been reporting a choice nothing reads since 29 Jul and is
one of the owner's seven open decisions. See `travel_mode_screen.dart` `WakeChoice`
and its Guardian Plus note.

**2. "On iOS the plugin runs its task in the main isolate anyway" is asserted, not
verified.** If true it is load-bearing and simplifying: the two-isolate problem is
Android-only and the iOS snapshot is computed in exactly one place. If false, the
gateway sits in the wrong isolate. Added to ticket 03's research list.

**3. A stale claim in `riverpod-adoption.md`, flagged here rather than fixed.**
That document's `rideAlertsProvider` rationale says the alert flags "cannot live
in `LiveRide` without breaking the recreation invariant". That has been false
since `91d52c8`: the flags are store-backed now. The split remains right, but for
its other stated reason, the media-session side effects. That document corrects
itself in place by convention and has earned the same treatment here.

## The four decisions still owed by the owner

1. Shape A over shape B.
2. Alert as an overlay flag rather than a phase.
3. Copy formatted in Dart and shipped to SwiftUI as strings.
4. The `_updateSurface()` unification of notification text and buttons.

Ticket 02 stays `claimed` until these are answered. It is NOT resolved, and the
map's Decisions-so-far deliberately does not yet list it.
