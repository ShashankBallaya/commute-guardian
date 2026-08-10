# Crash reporting (Sentry)

Set up 8 Aug 2026. Free tier. Code lives in `lib/services/crash_reporting.dart`.

## The DSN never goes in the repository

This repository is **public**. The DSN is passed at build time and is absent
from every checkout:

```
cp secrets.example.json secrets.json   # then paste the DSN in
flutter run --dart-define-from-file=secrets.json
flutter build apk --dart-define-from-file=secrets.json
```

`secrets.json` is gitignored and also carries the Aptabase key (see
[analytics.md](analytics.md)). With no DSN, `CrashReporting.isEnabled` is false,
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

- **UI isolate** (`main.dart`): `CrashReporting.startUiIsolate()`, called
  **after `runApp` and never awaited**. See the warning below, which is the most
  expensive thing this file has to say.
- **Service isolate** (`geofence_task_handler.dart`): the pure Dart
  `Sentry.init`, awaited at the top of `onStart` but bounded to two seconds. It
  runs in a background isolate spawned by the foreground service and must not
  touch Flutter's native bindings a second time.

### CRASH REPORTING MAY NEVER HOLD THE FIRST FRAME

This used to be `SentryFlutter.init(..., appRunner: () => runApp(...))`, which is
the arrangement the SDK documents and which reads as the safer one. It is not.

On 10 Aug 2026 the first IPA ever built with a real DSN **showed a white screen
forever on the iPhone and never reached the home screen.** The same commit started
normally on Android, and a build with the DSN removed and the Aptabase key kept
opened instantly, which is what identified the culprit instead of guessing at it.

The mechanism is in the package. `Sentry._init` (sentry 9.26.0) does:

```dart
await _callIntegrations(integrations, options);
await appRunner();
```

**Every integration is awaited before the app runs, with no timeout around the
loop**, and one of them initialises the native SDK over a method channel. An
integration that never returns is therefore an app that never draws.

So the app starts first and Sentry comes up behind it. The cost is real and
accepted: an error thrown in the first few hundred milliseconds is not reported,
and the zone capture `appRunner` provided is gone. `FlutterError.onError` and
`PlatformDispatcher.instance.onError` are still installed by Sentry's own default
integrations once init finishes, so everything after startup is still caught.

This is the same rule the rest of the project already follows: `Aptabase.init` is
fired and forgotten, the service isolate's init is bounded, and `_EntryGate`
ignores the analytics boot on purpose. **Nothing that observes a ride may prevent
one.** Four tests in `crash_reporting_test.dart` read `main()` and assert the
order, including one that proves the guard can still fail.

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

- **No opt-out toggle for CRASHES.** Settings' "Share anonymous usage" switch
  governs analytics only. Crash reporting was never specified in the locked
  design. Decide before the beta, along with the privacy copy that has to name
  Sentry.
