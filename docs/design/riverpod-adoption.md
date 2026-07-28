# Riverpod adoption: architecture

Status: proposed, awaiting owner sign-off. Branch: phase2-riverpod, cut from
5781b8d. No implementation exists yet; this document is the design.

The ride baseline on both phones is c9e5bf4. NOTHING from this branch may be
installed on either phone until the Phase 1 verification ride has happened,
so every gate below is a desk gate (tests, analyzer, replay), never a device
install.

## The one-sentence architecture

Riverpod lives in the UI isolate only; the service isolate keeps its current
shape, the bridge keeps its current wire format, and every provider that
describes the running ride is an explicitly stale read model seeded from the
shared store, so activity recreation is a non-event by construction.

## Scope and non-goals

In scope: lib/main.dart (1649 lines, 30 setState sites) and the state model
for the six coming product screens (home, journey setup, active journey,
arrival, settings, history).

Not in scope, deliberately:

- The service isolate. lib/foreground/geofence_task_handler.dart owns the
  bridge itself (it sends typed map payloads such as {'wakeLadderLive': live}
  and reads the saveData keys), and geofence_chain_service.dart is the
  field-proven core. The only permitted change there is ADDITIVE: new
  sendDataToMain payloads and new saveData keys as the Active Journey screen
  needs them. No log string changes (tool/replay_ride.dart parses them), no
  restructuring.

  CORRECTED DURING STEP 1: an earlier draft of this document called the task
  handler the single service-side file touching the plugin. It is not.
  geofence_chain_service.dart also calls
  FlutterForegroundTask.isIgnoringBatteryOptimizations, to log the permission
  picture at ride start. That is not bridge traffic and it is legitimate,
  because that file runs in the service isolate. The invariant the boundary
  test actually enforces is therefore one-sided: the UI ISOLATE has exactly
  one door (RideServiceClient); service-isolate files use the plugin freely.
- The engines (ride_progress, wake_escalation, wind_down, journey_planner).
  Pure Dart, no Riverpod imports, tests untouched. They are the only code in
  this project proven on a train.
- The service isolate gets NO ProviderContainer. Riverpod is a UI-isolate
  dependency, full stop.

## Domain language the providers are named in

From CONTEXT.md (Ride section, added with this design):

- A JOURNEY is the plan: chain, interchanges, overshoot pins. Derivable at
  any time from origin, destination and station data. It has no progress.
- A RIDE is one execution of a journey. Its progress lives only in the
  service isolate and cannot be recomputed, only reported.
- TRAVEL MODE is the rider-facing name for a live ride, used in copy.

The distinction is load-bearing for the architecture: derivable state gets
derived providers (recompute on rebuild, nothing to lose), execution state
gets a projection seeded from the store (recover on rebuild, nothing to
lose). The recreation bug existed because the two were tangled in one
widget's setState.

## Provider graph

| Provider | Type | Owns | Depends on |
|---|---|---|---|
| stationRepositoryProvider | FutureProvider\<StationRepository\> | the parsed 127-station data, loaded once, kept alive | nothing |
| rideServiceClientProvider | Provider\<RideServiceClient\> | the bridge facade (below) | nothing |
| journeyDraftProvider | Notifier\<JourneyDraft\> | the picked origin and destination ids, nothing else | nothing |
| plannedJourneyProvider | Provider\<Journey?\> | nothing (pure derivation) | journeyDraftProvider, stationRepositoryProvider |
| liveRideProvider | AsyncNotifier\<LiveRide?\> | the projection of the running ride; null means no ride | rideServiceClientProvider |
| nearestStationProvider | AsyncNotifier\<NearestStationState\> | the pre-ride "You're near" chip state, with a locate() retry | stationRepositoryProvider |
| journeyHistoryDbProvider | Provider\<JourneyHistoryDb\> | the drift database handle | nothing |
| rideHistoryProvider | FutureProvider\<List\<JourneyRecord\>\> | the history rows, newest first | journeyHistoryDbProvider |

Eight providers. If this number wants to triple during implementation,
something is wrong; stop and re-read "what is not a provider".

AS BUILT, steps 0 to 3 came to eleven, and the three extras are worth naming
so the budget stays honest rather than quietly abandoned:

- stationsAlphabeticalProvider, a one-line derivation, so the pickers' sort
  does not run on every rebuild.
- isRideRunningProvider, a one-line derivation over liveRideProvider, because
  half the screen asks only that question.
- rideAlertsProvider, which is NOT a convenience. It exists because the ladder
  and wind-down flags are the one part of the running ride that the service
  does not persist, so they cannot live in LiveRide without breaking the
  recreation invariant that class is built on. Splitting them documents which
  half of the state model recovers and which does not.

plannedJourneyProvider is the showcase of the Journey/Ride distinction: it is
a synchronous pure function (JourneyPlanner.plan) of the draft and the
repository, so it needs no Notifier, no persistence and no recreation logic.
Kill the process mid-pick and the draft is gone (acceptable, it is two taps);
kill it mid-ride and the ride recovers (mandatory, see below).

## The bridge: RideServiceClient

The single UI-isolate object allowed to import flutter_foreground_task. It
mirrors the discipline the service side already has in
geofence_task_handler.dart.

It owns, exactly:

1. COMMANDS. Typed methods (startRide, endRide, ackWake, windDownEndNow,
   windDownExtend, the test triggers) that emit the EXISTING string commands
   via sendDataToTask. Wire format unchanged; the strings become private
   constants of the client.
2. EVENTS. The addTaskDataCallback registration, parsing the existing map
   payloads into a typed broadcast Stream\<ServiceEvent\>
   (WakeLadderChanged, WindDownChanged, RideEnded, and additive future
   events such as StationPassed for the Active Journey screen).
3. STORE READS. readPersistedRide(), wrapping the getData keys plus the
   plugin's is-running query, returning what liveRideProvider needs to seed.
4. THE EARPHONE ACK FORWARDING. The media-button subscription that today
   lives in the widget (main.dart around line 268) is bridge traffic and
   moves into the client.

Journeys cross the bridge as IDS, never as objects. The UI saves originId
and destinationId to the store and starts the service; the service replans
with its own repository, exactly as today. Two isolates, one planner, zero
serialization of Journey.

Enforcement is a test, not a convention: a test greps lib/ and fails if
'FlutterForegroundTask' appears outside ride_service_client.dart and
lib/foreground/. Same pattern as the test that parses build_clip_pack.py to
stop copy drift.

## The recreation invariant (the bug this design deletes)

The blank-route bug happened because process death took the widget state and
nothing re-read the live ride. The fix is structural:

  EVERY FACT IN LiveRide MUST BE RECOVERABLE FROM THE SHARED STORE ALONE.
  THE EVENT STREAM IS ONLY THE LOW-LATENCY PATH.

Concretely: liveRideProvider.build() calls client.readPersistedRide() and
constructs the projection from the store (or null when no ride is live),
then subscribes to the event stream for updates. A recreated process runs
build() again and gets the same answer the dead process had. No widget
participates; the debug screen's _onReceiveTaskData handler is deleted, not
migrated.

Consequence for the service, additive only: any new fact the Active Journey
screen displays (for example the last station passed) must be BOTH evented
via sendDataToMain and persisted via saveData when it changes. The service
already does this for destinationReached; new keys follow the same pattern.
Which keys exist is decided screen by screen at implementation time.

## Decisions, with reasons

1. NO riverpod_generator, hand-written providers. Eight providers is below
   the boilerplate threshold where codegen pays; build_runner is already in
   the loop for drift and this keeps it out of the state layer; and
   hand-written Notifier classes teach the actual mechanics (the owner is
   learning Dart; this is also the agreed /teach lesson slot). Revisit only
   if the provider count grows past twenty.

2. HISTORY IS A FutureProvider.autoDispose. No drift.watch(), and no
   invalidation wiring either.

   CORRECTED IN STEP 4, and the correction matters more than the decision.
   This entry originally read "NEVER drift.watch()" and justified it by
   claiming history rows are WRITTEN IN THE SERVICE ISOLATE over a different
   database connection, so a stream query could never see them. THAT IS
   FALSE. Only lib/main.dart ever opens, reads or writes this database; the
   service isolate does not touch it. Rides are recorded from the screen's
   own teardown path, on the same connection a stream would use, so
   drift.watch() would in fact have worked. The design was right by accident
   and for the wrong reason, which is worse than being wrong, because the
   next person would have believed the reason.

   The real reason, now that the fact is straight: the history sheet is a
   MODAL, so it wants a query on open, not a subscription for the life of
   the app. autoDispose gives exactly that. The provider lives while the
   sheet is open and re-runs the query the next time it opens, which is the
   "reads fresh from the database on every open" behaviour the sheet already
   documented for itself. Nothing to invalidate, nothing to forget, and no
   permanent query subscription for a screen that is rarely on.

   Watch for this in TESTS: override journeyHistoryDbProvider with
   overrideWith, never overrideWithValue. The latter builds the database
   eagerly for every test and skips the create function, so the onDispose
   that closes it never runs, and drift starts warning about a second
   instance of the database class racing on one file.

3. "A RIDE IS LIVE" IS A STORE FACT, NOT A WIDGET FACT. Liveness is the
   plugin's is-running state plus the persisted keys, read in build().
   The UI can never invent a ride the service is not running, and can never
   blank a ride it is.

4. STATION REPOSITORY IS A keepAlive FutureProvider. Loaded once per
   process, immutable, shared by the picker, the planner derivation and the
   nearest-station chip. The service isolate keeps loading its own copy, as
   today.

## What is NOT a provider

- The engines. Stated again because it is the most tempting mistake.
- The search sheet's query text and filtered list: per-sheet ephemeral
  state, stays a StatefulWidget.
- Text controllers, scroll controllers, focus nodes, animation state.
- The debug log widget's scroll position; the debug screen dies anyway.
- Anything whose loss on process death costs the user two taps or less.

## Migration order

The gate at EVERY step: flutter test green (never fewer than 140), flutter
analyze clean, and the replay corpus byte-identical
(dart tool/replay_ride.dart with explicit origin and destination). The
replay gate is the tripwire for accidental service-side edits.

- STEP 0: add flutter_riverpod, wrap runApp in ProviderScope, add the one
  shared pump helper edit that wraps widget-test pumps in ProviderScope.
  Zero behavior change. Gate.
- STEP 1: extract RideServiceClient as a plain class (no providers yet).
  Move every direct FlutterForegroundTask call in main.dart into it,
  including the media-button forwarding. Add the grep-enforcement test.
  This is the riskiest mechanical step, done while everything else is
  still familiar. Gate.
- STEP 2: stationRepositoryProvider, journeyDraftProvider,
  plannedJourneyProvider, nearestStationProvider. Migrate the picker and
  chip setState cluster (roughly 8 of the 30 sites). Gate.
- STEP 3: liveRideProvider. Migrate the ladder, wind-down and ride-status
  cluster (roughly 10 sites). DELETE _onReceiveTaskData from the widget.
  Add the recreation test: pump the app with a fake client whose store
  says a ride is live, assert the route renders with zero user actions.
  This is the step that kills the bug. Gate.
- STEP 4: journeyHistoryDbProvider, rideHistoryProvider, the RideEnded
  invalidation. Migrate the history sheet and the remaining debug-button
  sites (roughly 12). Gate.
- STEP 5: sweep. Grep for setState referencing ride or journey state
  (should be zero), delete dead fields, final gate.

Each step is one commit. If a step cannot end green, it is too big; split
it rather than pushing through.

## Testing approach

- Engine and service tests: ZERO changes. They never touch Riverpod.
- Widget tests: assertions untouched; the single pump helper gains
  ProviderScope with two standing overrides, stationRepositoryProvider
  (in-memory stations the tests already construct) and
  rideServiceClientProvider (a FakeRideServiceClient that records commands
  and replays scripted ServiceEvents). One helper edit, not per-test
  rewrites.
- New tests, four: the client parses each existing payload shape into the
  right ServiceEvent; liveRideProvider reduces a scripted event sequence
  correctly; the recreation test (step 3); the FlutterForegroundTask grep
  test (step 1).
- ProviderContainer unit tests need no widgets: container.read, pump the
  fake stream, assert states.

## Challenged and rejected shapes

- A provider that wraps the service as if it were local (call a method, get
  ride state back synchronously). Rejected: it lies about the isolate
  boundary, and the lie surfaces exactly when the phone is locked in a
  pocket, where every hard bug in this project has lived. Commands are
  fire-and-forget; confirmation arrives as an event or not at all.
- Engines behind providers "for testability". Rejected: they are pure and
  already tested; wrapping them adds a dependency to the only field-proven
  code for zero coverage gain.
- Riverpod in the service isolate. Rejected: no UI there, nothing to
  observe, and the 22-24 Jul evidence chain depends on that code staying
  still.
- drift.watch() for history. Rejected above; recorded here because it is
  the shape every Riverpod tutorial reaches for first.
- A settingsProvider. Premature: no settings screen exists and no setting
  is persisted today. It arrives with the Settings screen in this same
  phase, backed by whatever store that screen decides.

## Deferred, recorded so it is not lost

- JourneyRecords (drift table) stores rides and should become RideRecords
  in ride_history.dart. Costs a migration; folded into the history screen
  work when that code is open anyway. Decided 28 Jul, deferred the same
  day.
- If riverpod_generator is ever adopted, it is a mechanical rewrite of
  eight small classes, not a redesign.
