# 08 - Does the app's iOS deployment target rise from 13.0?

> **27 AUG 2026: ANSWERED PROVISIONALLY. The app stays at 13.0.**
>
> The extension carries its own 16.1 and the ActivityKit calls sit behind
> `if #available(iOS 16.1, *)`. Checked at the desk: all three build configs in
> `project.pbxproj` read `IPHONEOS_DEPLOYMENT_TARGET = 13.0`.
>
> This needs no market number, because nobody is excluded either way. Reopen it
> only if a dependency forces the host app higher.
>
> No longer blocked: 01's risk evaporated with the Apple enrolment. See `map.md`.


Type: grilling
Status: open
Blocked by: 01

## Question

`IPHONEOS_DEPLOYMENT_TARGET = 13.0` today. Live Activities need 16.1.

An extension can carry its own higher target while the host app stays at 13.0, so
this is not forced. The question is whether keeping the app at 13.0 is worth it.

To settle:

- Who is actually excluded. iOS 13 runs on iPhone 6s and SE 1st gen. In the Indian
  market, and specifically among the iPhone owners the owner says he now sees on
  the local, what share is below 16.1? This wants a real number, not a guess.
- What 13.0 costs to keep. Whether any dependency already wants higher, and whether
  the conditional-availability code around a 16.1-only feature is a lasting tax.
- Whether the App Store listing and the "minimum iOS" line matter to positioning.

Blocked on 01 because if the extension will not sideload, this decision is moot
until an Apple account exists, and its answer may be bundled into that purchase.
