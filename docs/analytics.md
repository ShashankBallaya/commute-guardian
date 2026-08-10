# Analytics (Aptabase)

Set up 8 Aug 2026. Free tier, privacy-first, no cookies, no advertising IDs.
Code lives in `lib/services/analytics.dart`.

## You do not build a dashboard

Aptabase is a hosted product. The charts, retention curves and event breakdowns
come with it at `app.aptabase.com`, in a browser. Same for Sentry. Nothing in
this repository serves a dashboard, and nothing should: a solo developer with
evenings does not spend them rebuilding a reporting UI that two vendors already
give away.

Self-hosting is possible (Aptabase is open source, Docker plus ClickHouse) and
is the escape hatch if the free tier ever stops being enough. It is not the
starting point, for the same reason Transistorsoft was not.

## The event list is two events, and that is deliberate

The project has five pre-committed numbers from the locked monetization design:

| Bar | Deadline | What reads it |
|---|---|---|
| 500 installs | 3 months | the Play Console, NOT Aptabase |
| 100 weekly active riders | 3 months | `ride_started` |
| Wake success 95 percent | 3 months | `ride_ended` outcome |
| D30 retention 40 percent | 3 months | **NOTHING. Not measurable.** |
| Kill floor: under 50 weekly active OR D30 under 20 percent | 6 months | half of it is not measurable |

### DEBUG AND RELEASE ARE TWO SEPARATE DATASETS. Read the bars from RELEASE

The SDK sends `isDebug: kDebugMode` with every event and Aptabase splits the data
on it. So:

- the 3T's debug APK, which is what every ride test runs, lands in **debug**;
- an IPA or a store build, `--release`, lands in **release**.

**Every bar in the table above must be read from the release dataset**, because
that is what a beta tester runs. The debug dataset is the owner's own two phones.
Noticed on 10 Aug 2026, when the first iOS event appeared under release while
every Android row sat under debug, which also explains why an export named
`commuteguardian-debug-*.csv` contained nothing but Android.

The cut goes both ways and both are correct: bench rides can never pollute the
real numbers, and a verification ride on the debug build does not count toward
wake success either.

### An app open sends NOTHING, so "initialising the SDK is the measurement" was wrong twice

Read `Aptabase._tick`: it pulls items from storage and, `if (items.isEmpty)
return`. Nothing is transmitted unless an event was queued, and this app queues
exactly two, both from a ride. **So opening the app produces no data at all**, and
a session only exists on the dashboard because a ride created one.

This is separate from the identity problem below and compounds it. Installs are
still measurable, just not here: the Play Console and App Store Connect report
them directly, which is the right source anyway. Retention is not measurable at
all.

### Retention is not measurable on this stack, and this doc used to say it was

This section claimed installs and retention needed no event at all, because
"Aptabase derives both from an anonymous per-device identity it generates
itself". **There is no such identity.** Aptabase has no device id, no cookie and
no fingerprint, by design and as advertised. Read the SDK: an event carries a
timestamp, a session id, the system properties and the props, and nothing that
survives the session.

The evidence is in the 9 Aug 2026 export. One 3T, one evening, five rides,
**three different `user_id` values**, changing while the phone moved between
towers. Whatever the server derives that column from, it is not a device.

So the two bars that count PEOPLE OVER TIME have nothing reading them. The two
that count EVENTS are fine, because we send those ourselves. Deciding what to do
about it is the owner's call, not this file's: it weighs a pre-committed bar
against the "no identifiers" position that made this design defensible in the
first place. Until that decision exists, do not report a retention number.

"Weekly active rider" means three or more Travel Mode rides in a week, so it
needs a ride count and nothing else. `ride_started` therefore carries **no
properties**. The count is the measurement.

Wake success needs to know how a ride finished:

```
ride_ended  { outcome, wake_armed, wake_answered }
```

`outcome` is one of four fixed words: `arrived`, `overshot`, `timeout`,
`ended_early`. `wake_armed` says the alarm actually had to work, which is what
makes the 95 percent honest: a ride where the rider was awake throughout says
nothing about whether the alarm functions, so the bar is measured over the
rides where the ladder ran. `wake_answered` then separates "the alarm woke
them" from "they were already awake", which is the difference between a product
that works and one that got lucky.

**An overshoot outranks an arrival.** A ride can do both: the destination is
announced, the rider sleeps through it, and the pin fires a stop later. Ranking
`arrived` first would report the product's central failure as its central
success. `test/analytics_test.dart` reads that ordering out of the service
source and asserts it, because reordering those branches breaks nothing else.

## What never leaves the device

No station ids, no station names, no line ids, no coordinates, no journey
duration. Only the two event names and three closed-set values above.

This is enforced, not promised. `analytics_test.dart` strips the comments from
`analytics.dart` and greps the remaining code for `station_id`, `lat`, `lng`,
`destination`, `origin` and friends, as whole words. It also asserts the event
list is exactly those two names. The way this feature would rot is one
useful-looking property at a time, and each one is another chance to ship
somebody's commute to a server.

## The opt-out

Settings, Privacy, "Share anonymous usage". **Opt-out, not opt-in**, per the
locked design. The switch and its storage existed before there was anything to
read them; this is the thing that reads them.

Off means nothing initialises and nothing is sent. A **missing** value also
means off: `shareUsageKey` defaults to false at the isolate boundary, and
`RideServiceClient.startRide` defaults the parameter to false, because absence
of an answer is not consent.

A rider who switches it off mid-session cannot un-initialise the SDK (Aptabase
has no teardown), but every event is checked at the moment of sending, so no
further ride is reported from the instant they opt out. The session ends with
the app.

## Both isolates, and why the ride events come from the service

- **UI isolate**: `analyticsBootProvider` starts the SDK once the opt-out has
  been read from drift. This records the app open, which is a session and no
  more than a session (see the retention warning above).
- **Service isolate**: `ride_started` and `ride_ended` fire here.

**THE TWO ISOLATES SHARE ONE EVENT QUEUE, AND THAT DOUBLE-COUNTED RIDES.**
`aptabase_flutter` queues events in SharedPreferences and flushes them on a
30 second timer, and `StorageManagerSharedPrefs.init()` copies every queued event
into an in-memory map ONCE, at startup. So an isolate that starts while the other
has events waiting adopts them and sends them a second time, with the original
timestamp, because the event's local key never leaves the device and nothing
de-duplicates at the far end. The 9 Aug export shows it: two of five rides
double-counted, identical timestamps, on the evening the app was force-stopped
and reopened mid-ride. Every isolate now gets its own queue.

The ride events are **not** sent from the UI, and that is the important
decision. The 30 Jul swipe bench proved the UI can die mid-ride while the
service rides on. Reporting from the UI would silently drop exactly the rides
that matter most: a pocketed phone with the app swiped away, which is the
product's actual use case. The measurement would then be biased toward the
rides where someone was watching the screen.

The opt-out reaches the service through the foreground-task store, the same
route the Pocket Pulse interval takes, because settings live in drift and the
service isolate never opens that database.

## Setting it up

1. Make an account at `aptabase.com`, create an app, copy the App Key. It looks
   like `A-US-1234567890`.
2. Paste it into `secrets.json` as `APTABASE_APP_KEY` (gitignored; copy
   `secrets.example.json` if the file is not there yet).
3. `gh secret set APTABASE_APP_KEY --body "<the key>"` so CI builds carry it.

Without a key, analytics is inert and the app runs normally. That is what every
clone and every test gets.

## What it costs the app, measured rather than assumed

- **Network**: three small requests per ride at most. One session on app open,
  one `ride_started`, one `ride_ended`. Against a ride that samples GPS at 1 Hz
  for an hour this is not measurable in battery terms.
- **Size**: `aptabase_flutter` is pure Dart over `shared_preferences`. Tens of
  kilobytes, not megabytes.
- **The ride path: NOTHING.** This is the part that needed work rather than
  assumption. `Aptabase.init` POSTS to the network before its future completes,
  the package sets no timeout, and Dart's `HttpClient` has none by default. The
  first wiring awaited that at the top of the service isolate's `onStart`,
  which put a hung socket between a rider and Travel Mode starting, in an app
  whose entire job is to start rides in cuttings and tunnels.

  So the ride path fires init and walks away. Events wait for readiness on the
  SEND side, where nothing is blocked, with a 10 second ceiling. Every send is
  wrapped in a catch, because these are fired unawaited from the start and stop
  of a ride, in the isolate whose death is silent. Sentry's init is still
  awaited but bounded to two seconds. `analytics_test.dart` asserts all of it.

## Still open

- **Nothing verifies the key reaches Aptabase.** Sentry got a debug button
  because crash reporting fails silently; analytics fails silently in the same
  way, and has no equivalent yet. It is also a worse fit: a test event would
  land in the same tables the pre-committed bars are read from, and would be a
  third event name the test list forbids. The cheapest honest check is the
  Aptabase dashboard showing a SESSION after a debug run, which needs no event
  at all. The two ride events need one real ride.
- **The privacy copy.** The store listing and the onboarding privacy line have
  to name Aptabase and Sentry, and say what each collects. Not written.
- **The retention clock only starts when this ships to real users.** Every day
  the build sits on two phones is a day the D30 measurement is not running.
