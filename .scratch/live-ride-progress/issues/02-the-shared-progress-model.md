# 02 - What is the shared progress model?

Type: grilling
Status: open
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
