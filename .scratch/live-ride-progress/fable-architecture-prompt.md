# Prompt for Fable: architect the shared ride-progress model

Paste the block below into a Fable session opened in `C:\dev\commute-guardian`.
It corresponds to ticket 02 of `.scratch/live-ride-progress/map.md`.

Fable is being asked to ARCHITECT, not to implement. The output is a design with
its trade-offs argued, not a pull request.

---

You are architecting one piece of a Flutter commuter-rail app, Commute Guardian.
Read `CLAUDE.md`, `CONTEXT.md` and `docs/design/riverpod-adoption.md` first. Do not
write production code in this session. Produce a design and argue its trade-offs.

## The problem

The app must show live ride progress on surfaces the rider reads WITHOUT opening
it: an updating ongoing notification on Android, and later a Live Activity on iOS.
Both are renderings of one shared progress model. A third rendering, the in-app
Active Journey screen (Screen 4), already exists and already shows the same facts.

Design the model and the path by which it reaches all three, such that they cannot
disagree.

## The constraints, which are not negotiable

**Two isolates.** The ride runs inside an Android foreground-service isolate with
its own heap (`lib/foreground/geofence_task_handler.dart`). The UI runs in the main
isolate. They communicate only by `sendDataToMain` / `sendDataToTask` messages and a
shared key-value store (`FlutterForegroundTask.saveData` / `getData`). The service
isolate cannot touch the UI's Riverpod container or the drift database.

**One projector, never two.** `lib/services/ride_progress.dart` is the single
authority on how far along the chain the ride has got. `lib/state/ride_providers.dart`
holds `LiveRide`, its store-backed projection on the UI side, which exists so an
activity the OS recreates mid-ride redraws correctly with no user action. A previous
version of this codebase had two things that could disagree about where the train
was, and it cost a real bug. Any new projector must justify itself against that.

**Store-backed or transient is a real distinction, and getting it wrong has bitten
before.** The invariant on `LiveRide` is that every field is recoverable from the
shared store alone. On 30 Jul a bench proved the opposite mistake: alert liveness
was transient and edge-triggered, so a UI that was recreated never learned an alarm
was sounding, and the rider could not acknowledge it. See commit `91d52c8`. Decide
deliberately which parts of the progress model are store-backed and say why.

**The notification is written from the SERVICE isolate.** `updateService` is called
from `geofence_task_handler.dart`, not from a widget. So the notification's content
must be derivable inside the service isolate. Screen 4's content is derived in the
UI isolate. That asymmetry is the crux of this design.

**iOS is different in kind.** A Live Activity is updated through ActivityKit from
the app process via a platform channel, not from the Dart service isolate, and iOS
has no ongoing-notification equivalent at all. Assume for now that local updates
without a backend are possible (this is being verified separately in ticket 03) but
design so that the answer being "no" damages one rendering rather than the model.

**No backend. Ever.** Everything on-device.

**Geofences fire on ENTER only.** Between two stations the app knows the last
station passed and nothing more precise. The design must not require a position the
data cannot supply.

## What to produce

1. The model itself: fields, which are stored and which derived, and from what.
2. Where it lives, and specifically whether the service isolate and the UI isolate
   each build it from the same pure function over the same inputs, or whether one
   builds it and sends it to the other. Argue the choice.
3. How Screen 4 stops being a separate derivation, or a defence of why it should
   stay one.
4. What crosses the isolate boundary, in what shape, and how often.
5. What survives process death and what does not, with the reason for each.
6. The seam where the iOS rendering attaches, given it is driven from the main
   isolate rather than the service one.
7. The failure modes you are deliberately accepting, and how each one looks to a
   rider on a train.

## How to argue it

Use the `/codebase-design` vocabulary: prefer a deep module with a narrow interface
over a wide one. Design it twice and compare, using `/design-an-interface`, rather
than presenting the first workable shape as inevitable.

Be concrete about this repo. Name the files and the existing types. If you believe
an existing decision recorded in `CONTEXT.md` or `docs/design/riverpod-adoption.md`
is wrong, say so explicitly and make the case; do not quietly design around it.
