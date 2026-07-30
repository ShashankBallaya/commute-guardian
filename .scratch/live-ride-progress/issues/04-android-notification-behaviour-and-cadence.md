# 04 - How does an ongoing notification behave when updated 30 times a ride?

Type: research
Status: open
Blocked by: none

## Question

The Android half looks cheap, and cheap things on Android are where the OEM
surprises live. This project already budgets for that: OEM battery killers are the
named top product risk, and Phase 0 existed to confront them.

Answer with citations to primary sources (Android developer documentation, and
where OEM behaviour is at issue, the vendor's own documentation or a reputable
tracker such as dontkillmyapp.com).

- `onlyAlertOnce: true` is set today. Confirm exactly what it suppresses on an
  UPDATE as opposed to a first post: sound, heads-up, or both.
- Is there a rate limit on updating an ongoing foreground-service notification?
  Android is documented to throttle notification updates in some versions. Find the
  actual rule and version range.
- `ProgressStyle` / Live Updates: which API level introduced it, what it renders,
  and whether the older `setProgress` bar is the right target instead. The test
  device is a OnePlus 3T, which is old; find out what it can actually show.
- Do MIUI, ColorOS or OxygenOS collapse, delay or dedupe frequent updates to an
  ongoing notification? MIUI and ColorOS are explicitly in the project's device
  matrix.
- Does updating the notification text reset or interfere with the notification
  ACTIONS? This matters directly: commit `91d52c8` composes actions from two live
  alert flags via `updateService`, and a text update must not wipe the "I'm awake"
  button off a sounding alarm.
- Battery cost of frequent `updateService` calls during the locked-screen stretch.
  Phase 0 passed on battery and that result must not be quietly spent.

Capture the findings as a markdown file in the repo and link it here.
