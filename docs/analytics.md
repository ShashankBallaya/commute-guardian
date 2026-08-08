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
| 500 installs | 3 months | Aptabase's own device identity |
| 100 weekly active riders | 3 months | `ride_started` |
| Wake success 95 percent | 3 months | `ride_ended` outcome |
| D30 retention 40 percent | 3 months | Aptabase retention |
| Kill floor: under 50 weekly active OR D30 under 20 percent | 6 months | both of the above |

Installs and retention need **no event at all**: initialising the SDK is the
whole implementation, because Aptabase derives both from an anonymous
per-device identity it generates itself.

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
  been read from drift. This records the app open, which is installs and D30.
- **Service isolate**: `ride_started` and `ride_ended` fire here.

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

## Still open

- **Nothing verifies the key reaches Aptabase.** Sentry got a debug button
  because crash reporting fails silently; analytics fails silently in the same
  way, and has no equivalent yet. The cheapest check is the Aptabase dashboard
  showing a session after a debug run.
- **The privacy copy.** The store listing and the onboarding privacy line have
  to name Aptabase and Sentry, and say what each collects. Not written.
- **The retention clock only starts when this ships to real users.** Every day
  the build sits on two phones is a day the D30 measurement is not running.
