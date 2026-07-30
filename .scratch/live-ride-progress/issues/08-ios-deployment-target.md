# 08 - Does the app's iOS deployment target rise from 13.0?

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
