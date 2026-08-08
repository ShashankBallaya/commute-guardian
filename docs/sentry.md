# Crash reporting (Sentry)

Set up 8 Aug 2026. Free tier. Code lives in `lib/services/crash_reporting.dart`.

## The DSN never goes in the repository

This repository is **public**. The DSN is passed at build time and is absent
from every checkout:

```
cp sentry.example.json sentry.json     # then paste the DSN in
flutter run --dart-define-from-file=sentry.json
flutter build apk --dart-define-from-file=sentry.json
```

`sentry.json` is gitignored. With no DSN, `CrashReporting.isEnabled` is false,
nothing initialises, and the app runs normally. That is what a clone, a fork
and every test gets, and it is a supported state rather than a broken one.

CI passes it as a repository secret named `SENTRY_DSN` (see
`.github/workflows/ios-build.yml`). **Add that secret or the IPA ships with
crash reporting off**, silently:

```
gh secret set SENTRY_DSN --body "<the dsn>"
```

A DSN is not a password. It is embedded in every shipped binary and anyone
with the app can extract it. Keeping it out of the public tree stops casual
event spam, nothing more, so do not treat a leak as a security incident.

## What is deliberately NOT collected

The rule is the Phase 4 privacy note: **no location ever leaves the device.**
A crash reporter is the most likely accidental route out, so the file switches
off every automatic collector by name rather than trusting a default:

| Setting | Why |
|---|---|
| `enablePrintBreadcrumbs = false` | The ride log is full of `FIX lat ..., lng ...` |
| `attachScreenshot = false` | Screen 4 draws the whole chain. A screenshot of it is a journey |
| `attachViewHierarchy = false` | Carries every station name on screen |
| `sendDefaultPii = false` | No IP address, no user identifiers |
| `tracesSampleRate = 0` | Performance monitoring spends quota and answers nothing here |

Then two filters run on what is left:

- `beforeBreadcrumb` **drops** any breadcrumb that looks like a position.
  A breadcrumb is context, and context that had to be censored is not worth
  sending.
- `beforeSend` **redacts** coordinates from event messages and exception
  values, keeping the rest of the sentence. "Geofencing error: cannot register
  region kalyan at LatLng([location removed])" is still a usable report.

`test/crash_reporting_test.dart` holds the redaction rules, using real lines
from the ride logs. It also asserts that ordinary numbers (`PULSE every 45s`,
`WAKE rung 3 of 5, volume 0.8`) survive untouched, because a scrubber that
eats version numbers and durations is a scrubber somebody switches off.

## Both isolates report

- **UI isolate** (`main.dart`): `SentryFlutter.init` with an `appRunner`.
- **Service isolate** (`geofence_task_handler.dart`): the pure Dart
  `Sentry.init`, awaited at the top of `onStart`. It runs in a background
  isolate spawned by the foreground service and must not touch Flutter's
  native bindings a second time.

Every event is tagged `isolate: ui` or `isolate: service`. **The service
isolate is the half that matters.** It has no screen, so a crash there is
silent: the ride stops watching and the rider finds out by missing their stop.
An OEM background kill is exactly the class of failure that never reproduces
on the two phones here.

Note that an OEM *killing* the service is not a crash and produces no event.
Sentry catches the service **crashing**, not the OS stopping it. Detecting a
kill needs a different instrument, and none exists yet.

## Proving it works

Crash reporting fails **silently**. A wrong DSN, a forgotten
`--dart-define-from-file` and a blocked network all look exactly like an app
that has not crashed.

So: debug screen, the bug icon in the scrolling preview row. It sends one
event and shows what happened in a snack bar, including "Crash reporting is
OFF: no DSN in this build."

## Still open

- **No opt-out toggle.** Settings has one for analytics by the locked
  monetization design; crash reporting was never specified. Decide before the
  beta, along with the privacy copy that has to name Sentry.
- Aptabase (analytics) is a separate item and still unbuilt. It is the one
  with a clock on it: retention cannot be measured retroactively.
