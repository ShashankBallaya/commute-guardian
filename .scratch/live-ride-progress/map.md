# Map: Live ride progress on the passive surface

Label: wayfinder:map
Charted: 30 Jul 2026

## Destination

A live ride-progress surface the rider reads without opening the app: one shared
progress model (where you are, which two stations you are between, what is next,
how many to go, terminal states), rendered natively as an updating ongoing
notification on Android and a Live Activity on iOS.

Done when the model is locked, Android ships it, and iOS either ships it or has a
known, priced reason not to.

## 27 AUG 2026: SCHEDULED, PRICED, AND ONE RISK REMOVED

Owner asked when the iOS Live Activity gets built, in his words: "I need
something what Uber/Blinkit/Zomato has." Answer given and agreed to record:
**mid to late September on a device.**

### Why not sooner, and it is not difficulty

Three iPhone testers are waiting on TestFlight in early September, and both
jobs draw on the same pool of 8 to 12 macOS runs a month. A Live Activity is
a surface, not safety: it does not wake anybody. When the two compete for a
run, testers with a date win.

    28 Aug          the ride. Nothing changes.
    29 to 31 Aug    notification shows live progress. Dart only, ZERO macOS
                    runs, works on all three phones.
    early Sept      Apple enrolment, then the TestFlight build.
    mid to late Sept  the Live Activity. Budget 4 to 6 macOS runs.

### THE BIG ONE: TICKET 01's PRICE RISK LARGELY EVAPORATES

Ticket 01 exists to find out whether a Widget Extension will sideload at all
on a FREE account, because a second App ID on a 7-day expiry might not, and
if it did not the iOS half cost USD 349.

**He is enrolling in the Apple Developer Program anyway**, for the early
September TestFlight (checklist A3). That purchase removes the second-App-ID
and 7-day-expiry problem that ticket 01 was written to price.

So do NOT spend an afternoon on ticket 01 as written. Re-scope it: after
enrolment the spike is simply the first build of the real extension, and its
question ("does this install") is answered by TestFlight itself. This also
unblocks ticket 08, which was blocked on 01.

### Ticket 08 answered, provisionally

The app STAYS at `IPHONEOS_DEPLOYMENT_TARGET = 13.0`. The extension carries
its own 16.1, and the ActivityKit calls sit behind `if #available(iOS 16.1,
*)`. Verified 27 Aug: three build configs in project.pbxproj all read 13.0.
Nobody is excluded and no market number is needed to decide it.

### Facts checked at the desk 27 Aug, so no session re-derives them

- `ios/Runner.xcodeproj/project.pbxproj` has **two native targets**, Runner
  and RunnerTests. A third must be added, blind, from Windows.
- **`NSSupportsLiveActivities` is absent** from `ios/Runner/Info.plist`.
- There is **no Podfile in the repo**; Flutter generates it. A widget
  extension needs no pods, so this is not a blocker.
- Live Activities need **no Apple enrolment to build or sideload**, so this
  work is not gated by A3. It is only sequenced behind it.

### TWO STALE FACTS IN THIS MAP, CORRECTED

1. "`showNotification: false` on iOS, iOS has NO passive surface today" is
   **out of date**. It shipped TRUE on 11 Aug (`3f9648b`). iOS has an ongoing
   notification with real buttons now. The Live Activity is an upgrade to
   something, not the first surface.
2. "The Android notification never updates" is **still true, on both
   platforms**. Title `Travel Mode active`, text `<origin> to <destination>`,
   set once at start and never touched. Only the BUTTONS change.

### DYNAMIC ISLAND IS OUT, AND THE HARDWARE SETTLES IT

The 30 Jul grilling ruled it out on reach. The phase 3 checklist then said
"Lock Screen plus Dynamic Island", which contradicts this map. The owner's
phone decides it: **Dynamic Island arrived with the iPhone 14 Pro and his is
an iPhone 13**, so he could never see or test one. Lock screen card only.

### HOW WE STOP IT BURNING macOS RUNS

The blind `pbxproj` edit is the only genuinely dangerous part. C1 already
beat this class of problem: it compiled green on its FIRST run because nine
Dart tests read the Swift source and checked its structure before a run was
spent. Same trick:

1. **Generate the target with a script**, never by hand. Deterministic,
   reviewable, re-runnable.
2. **Desk tests that parse `project.pbxproj`** and assert the third target
   exists, that its product type is `com.apple.product-type.app-extension`,
   that its deployment target is 16.1, and that it is in the app's Embed App
   Extensions copy phase.
3. **A test asserting `NSSupportsLiveActivities` is true** in Info.plist.

That is what turns "blind" into "checked" and why 4 to 6 runs is realistic
rather than optimistic.

### WHAT IT SHOWS

Uber shows a map and an ETA. The train equivalent is the wayfinder already
specified and MEASURED for Screen 1: the five-dot line strip redrawn in
SwiftUI, next station, stops remaining, ETA, and the whole card switching to
the alarm state while the wake ladder is live. The design work is done; see
[[screen-1-line-strip]].

Updates are **LOCAL**, driven from the ride's own isolate through a method
channel into Swift, because push updates need APNs and that is a backend.
Roughly 30 updates a ride, well inside what iOS allows. Reuse the channel
pattern `RelaunchLifeline` already registers on both engines.

### THE CHEAP HALF THAT LANDS FIRST

`FlutterForegroundTask.updateService` already takes `notificationText` and
the handler already calls it for buttons. One Dart change gives, on the 3T's
Android 9, the moto AND the iPhone lock screen:

    Travel Mode active
    Next: Parel  .  3 stops  .  ~11 min

No Kotlin, no Swift, no pbxproj, no macOS run. It is the part of the Uber
feeling that is about information rather than chrome. Do this first.

## Notes

**Domain.** Flutter, Dart. Suburban rail commuter app, Mumbai local first. See
`CLAUDE.md` and `COMMUTE_GUARDIAN_HANDOVER.md`.

**Skills every session should consult.** `/emil-design-eng` at the START of any
surface or layout work, not after (standing instruction, 29 Jul). `/grilling` and
`/domain-modeling` for the decision tickets. `/prototype` for the rendering
tickets.

**Standing preferences for this effort.**

- No em dashes anywhere, and no hyphen-as-separator in UI copy.
- Crimson is reserved for actions that start or end a journey. Nothing else gets
  crimson fill. A "must be loudest and is not a journey action" control is WHITE
  FILL, per the shipped "I'm awake" button.
- Sentence case in all copy.
- Android is the platform that must ship. iOS is in scope but its provisioning
  risk is front-loaded into ticket 01, never allowed to become the spine.
- Type scale is set against 1080x1920, not a 390pt frame. A scale that reads well
  in Figma has been too big on the owner's actual phone twice.

**Facts established while charting, so no session re-derives them.**

- `showNotification: false` on iOS (`lib/services/ride_service_client.dart:220`).
  iOS has NO passive surface today. This would be the first one, not an upgrade.
- The Android notification never updates. Title `Travel Mode active`, text
  `<origin> to <destination>`, both set once at `startService` and never touched.
  `onlyAlertOnce: true`. It says the same thing at Shahad and at Andheri.
- `FlutterForegroundTask.updateService` accepts `notificationTitle` and
  `notificationText` (plugin line 158). The service isolate already fires
  `onProgress(reachedIndex)` and already holds the journey. The Android half is a
  small change in `lib/foreground/geofence_task_handler.dart`, a file already
  touched on 30 Jul.
- Android notifications have a NATIVE progress bar. The rail does not have to be
  drawn.
- iOS has no ongoing-notification equivalent. The only live surface is a Live
  Activity, which requires a Widget Extension: a second App ID with its own
  provisioning profile, on a free 7-day sideload today.
- iOS deployment target is 13.0 (`ios/Runner.xcodeproj/project.pbxproj`). Live
  Activities need 16.1+. There is no extension target in `ios/`.
- THE NO-BACKEND RULE DOES NOT BITE HERE, and this is the unlock. Uber, Zomato
  and Blinkit push Live Activity updates from a server through APNs because only
  the server knows where the rider is. This app knows on-device and already holds
  background location and background audio, so it can update its own Live
  Activity locally through ActivityKit with no push and no server.
- Screen 4 already projects the same data (mini-rail, count remaining, position).
  Any new projector risks being a second place that can disagree with it.

## Decisions so far

<!-- one line per resolved ticket: gist, then open the ticket for detail -->

- [02 What is the shared progress model?](issues/02-the-shared-progress-model.md) —
  `RideSnapshot`: one pure factory over primitives that already cross the isolate
  seam, so NOTHING NEW IS PERSISTED and it is a projection of `RideProgress`
  rather than a second projector. Both isolates call the same function; copy is
  formatted in Dart; alerts are overlay flags, not phases; notification text and
  buttons ship in one `_updateSurface()` call. Full design in
  `docs/design/ride-snapshot.md`. Killed UI-isolate rendering permanently.

## Not yet specified

Fog: in scope, not yet sharp enough to ticket. Graduates as the frontier advances.

- ~~**The surface during an alert.**~~ GRADUATED 30 Jul into ticket 05, once
  ticket 02 settled that alerts are overlay flags rather than phases.
- **Language.** The app speaks Hindi and Marathi through TTS. Whether the passive
  surface follows, and what that costs on a notification that updates 30 times a
  ride.
- **ETA on the surface.** ETA was formally moved to Phase 3 on 29 Jul, with
  `etaLine` on Screen 4 kept as its seam. Whether the passive surface shows one,
  or inherits that seam, is a live question but hangs on the model.
- **Pocket Pulse on the surface.** Pocket Pulse is still zero lines. Whether its
  state belongs here at all is unanswerable until the feature exists.
- **Guardian Plus.** Whether any part of this surface is a paid tier. The locked
  monetization design says free gets complete safety, and this surface is
  arguably safety.

## Out of scope

Ruled beyond the destination. Never graduates; returns only as a fresh effort.

- **Dynamic Island specifically.** Owner ruled it out during charting, 30 Jul.
  Reach is (Mumbai local commuter) intersect (iPhone) intersect (14 Pro or
  newer), and the positioning it leans on ("the Mumbai local app") is already a
  locked no. Lock-screen Live Activities stay in scope; the Island does not.
- **Backend push updates.** No backend is locked, and this feature does not need
  one: updates are local.
- **Watch and Android Wear.** No Apple Watch in v1 is locked.
