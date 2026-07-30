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

_None yet. The map was charted 30 Jul 2026._

## Not yet specified

Fog: in scope, not yet sharp enough to ticket. Graduates as the frontier advances.

- **The surface during an alert.** What the notification says while the wake
  ladder is climbing, and during the wind-down countdown. Entangled with the
  30 Jul ack work (commit `91d52c8`) which put an "I'm awake" action there and
  composes actions from both alerts. Needs the progress model settled first.
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
