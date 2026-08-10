# "No backend" means none of OURS, and two third-party SDKs report from the app

Status: accepted (10 Aug 2026)

CLAUDE.md locks "no backend for MVP. Everything on-device: geofences, timetable
data, TTS." Sentry (crash reporting) and Aptabase (analytics) shipped on 8 Aug
2026 and both send data off the device, so the locked wording is no longer true as
written. ADR 0001 set the precedent that changing it needs an ADR, and it named
this exact case: "adopting it would amend the no-backend decision and needs its
own ADR."

The decision is a narrowing rather than a reversal. **The prohibition is on a
backend of ours: a server we write, deploy, operate and that the app depends on.**
That prohibition stands completely and is what the original decision was for: no
service to keep alive, no auth, no per-user cost, no thing to be down while a
rider is asleep on a train.

Two properties make Sentry and Aptabase compatible with it, and both are load
bearing rather than incidental:

- **Nothing in the rider's path waits on them.** No announcement, no geofence, no
  wake ladder, no arrival reads from a network. `Aptabase.init` posts before its
  future completes, so it is fired and forgotten; the service isolate's Sentry init
  is bounded to two seconds; `_EntryGate` deliberately ignores the analytics boot.
  On 10 Aug the one place this rule had not been applied cost the entire app: the
  UI isolate's Sentry init wrapped `runApp` and an iOS integration never returned,
  so the app never drew a frame (see `docs/sentry.md`). That is what the rule is
  for, and it now holds everywhere.
- **They are write-only and off by default in a checkout.** Both keys arrive as
  build-time defines and are absent from this public repository, so a clone, a CI
  run and every test get an app with both compiled out and working normally. The
  app never reads anything back. There is no state on a server that the app needs,
  which is the actual test of whether something is "a backend".

## What is still refused

- **A server of ours, for the MVP.** Unchanged.
- **A network call inside the offline wake path.** Refused permanently, not just
  for the MVP. ADR 0001 rejected live cloud TTS on exactly this ground.
- **Reading anything back from a network to decide a ride.** Journeys are planned
  from bundled station data. There is no remote config, no feature flag service,
  no fetched timetable.
- **Anything that ships a rider's journey.** Enforced rather than promised: no
  station id, name, line or coordinate may enter either payload, and tests read
  the source and grep for the words a leak would be spelled with
  (`analytics_test.dart`, `crash_reporting_test.dart`).

## Consequences, including one that is unwelcome

Two vendors are now in the trust boundary, and the privacy copy for the store
listing and onboarding must name both. That copy is unwritten.

**Aptabase cannot measure retention, and the design assumed it could.** Aptabase
has no device identity by design: no device id, no cookie, no fingerprint. It was
recorded in `analytics.dart` and `docs/analytics.md` that installs and D30 came
"from Aptabase's own anonymous per-device identity", and there is no such thing. The
9 Aug export shows one phone producing three `user_id` values in one evening on a
moving train. So D30 at 40 percent and the D30 kill floor, two of the five
pre-committed bars in the locked monetization design, currently have nothing
reading them.

That is left open here on purpose, because the fix is a product decision and not an
architectural one. The options are to keep an anonymous install id on the device and
send it (measurable, and a deliberate step away from the position this ADR just
defended), to replace D30 with a measurable proxy, or to drop the retention bars and
keep the outcome bars. **Until that is decided, no retention number should be
reported.**

## If a backend is ever built

Unchanged from the handover: Cloudflare Workers plus D1. The first genuine
candidate is live guardian journey sharing (Phase 3), which cannot work without
one. A clip-pack bucket (ADR 0001's lead candidate, Cloudflare R2) would be
read-only static hosting and would need its own ADR, because unlike these two SDKs
the app WOULD depend on reading something back.
