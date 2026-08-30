# What leaves the phone, and what does not

Written 30 Aug 2026. **Every line here was read off the code, not remembered.**
This file is the fact base for the privacy policy and the Play Data Safety
form. A wrong Data Safety answer is the only TAKEDOWN risk on the launch list,
so when the code changes, change this file in the same commit.

## 1. Location. Collected on device, NEVER transmitted.

The app reads GPS continuously during a ride. That is the product. It is used
to cross geofences, announce stations and sound the alarm. It is never sent
anywhere, and the code goes out of its way to keep it that way:

| Guard | Where | Why it exists |
|---|---|---|
| `attachScreenshot = false` | `crash_reporting.dart:121` | Screen 4 draws the whole chain, so a screenshot IS the rider's route |
| `attachViewHierarchy = false` | `crash_reporting.dart:126` | The hierarchy carries every station name on screen |
| `sendDefaultPii = false` | `crash_reporting.dart:225` | No IP, no username |
| `tracesSampleRate = 0` | `crash_reporting.dart:218` | No performance traces |
| `enablePrintBreadcrumbs = false` | `crash_reporting.dart:224` | Ride logs print coordinates thousands of times |
| `beforeBreadcrumb = _dropLocationBreadcrumbs` | `crash_reporting.dart:226` | Drops any breadcrumb that looks like a position |
| `beforeSend = _scrubEvent` | `crash_reporting.dart:227` | Rewrites coordinates out of messages and exception values |

The scrubber matches three real shapes, taken from the app's own logs and not
invented: `lat 19.2358216, lng 73.1308101`, `LatLng(...)`, and a bare decimal
pair. See `crash_reporting.dart:269-283`.

## 2. Analytics. Aptabase. Two events, opt-out.

Opt-out flag is `AppSettings.shareAnonymousUsage` (`app_settings.dart:82`),
OPT-OUT rather than opt-in per the locked monetization design.

**Every event the app can send, in full:**

    ride_started    no properties at all
    ride_ended      outcome, wake_armed, wake_answered

`analytics.dart:211` and `analytics.dart:226`. There is no third event.
`trackRideInterrupted` is a `ride_ended` with `outcome: interrupted`.

**No station, no route, no coordinate, no time of day of a journey is in any
of them.**

**What the Aptabase SDK adds to every event by itself**
(`aptabase_flutter-0.5.0/lib/aptabase_flutter.dart:171-181`, `sys_info.dart`):

    osName, osVersion, appVersion, buildNumber, locale, sdkVersion, sessionId

`sessionId` is `RandomString.randomize()` generated in memory per run
(`aptabase_flutter.dart:45, 282`). **It is not a persistent device identifier
and it does not survive a restart.** The SDK sends no device model.

Aptabase's own servers see the request IP at ingest, as any HTTP endpoint does.

## 3. Crash reports. Sentry.

Stack traces, the isolate tag, and Sentry's standard device and OS context.
Scrubbed as in section 1. Sentry's servers see the request IP at ingest.

## 4. The ride log export. Rider-initiated, and it DOES contain the route.

`ride_log_export.dart` opens the platform share sheet. The rider chooses
whether to send it and who to send it to. **The log names every station they
passed and carries raw fixes**, which is why the file's own comment says it is
"not ours to hoover up" (`ride_log_export.dart:31`).

Nothing is uploaded automatically. This path exists only because a missed
station on somebody else's phone cannot be diagnosed any other way.

## 5. Journey history. On device only.

SQLite via Drift. Never uploaded, never backed up off the phone. A reinstall
wipes it, which is why moving testers from a sideload to Play costs them their
history.

---

# Play Data Safety answers

**These are recommendations with the reasoning attached, not rulings. Read
Google's own wording in the console before you submit, because this form is
the takedown risk.**

| Section | Answer | Why |
|---|---|---|
| Location (approximate and precise) | **Not collected** | Play defines collection as transmission off the device. Location is processed on device and every automatic path off it is closed by name in section 1. See the judgment call below. |
| App activity > App interactions | **Collected, not shared.** Purpose: Analytics. **Not** linked to identity. Users can opt out. | The two Aptabase events |
| App info and performance > Crash logs | **Collected, not shared.** Purpose: Analytics / App functionality. Not linked to identity. | Sentry |
| App info and performance > Diagnostics | **Collected, not shared** | OS version, app version, locale from the Aptabase system props |
| Device or other IDs | **Not collected** | `sessionId` is random per run and does not persist. No advertising ID, no device model. |
| Personal info, financial, health, contacts, photos, files, messages, calendar | **Not collected** | The app has no account, no login and no server of ours |
| Encrypted in transit | **Yes** | Both endpoints are HTTPS |
| Users can request deletion | Answer honestly. There is no account to delete, and the opt-out stops future collection. | |

## THE ONE JUDGMENT CALL, and it is yours

**Does the ride log export make location "collected"?** The reading I would
take is no: the rider chooses to send it, chooses the destination through the
system share sheet, and the app uploads nothing on its own. Google's guidance
carves out data a user sends deliberately through a system intent. **But this
is the single answer on the form that could be argued the other way, so read
Google's exact wording rather than trusting this table, and describe the
export plainly in the policy either way. The policy already does.**

# The other Play gates this app trips, which are NOT the Data Safety form

1. **`ACCESS_BACKGROUND_LOCATION` triggers the Location Permissions
   declaration**, and that needs a **VIDEO showing the in-app feature that uses
   it**. Verified in `AndroidManifest.xml`. This is the gate people
   underestimate, and you are already planning to shoot footage, so shoot this
   clip at the same time. It is a separate clip from the film: it must show the
   feature working, not sell anything.
2. **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is a restricted permission.** It is
   declared in the manifest. Be ready to justify it as core to a background
   alarm, and expect it to draw a reviewer's eye.
3. The prominent in-app disclosure before the background location prompt is a
   separate policy requirement from the store form. That copy is already
   written; see the onboarding permission sequence.
