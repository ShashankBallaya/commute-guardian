# 01 - Can a Widget Extension sideload onto the iPhone at all?

> **27 AUG 2026: RE-SCOPE THIS. Its price risk has largely evaporated.**
>
> This ticket exists to find out whether a Widget Extension will sideload on a
> FREE account, because a second App ID on a 7-day expiry might refuse, and if
> it did the iOS half cost USD 349.
>
> **The owner is enrolling in the Apple Developer Program anyway**, for the
> early September TestFlight (phase 3 checklist A3). That purchase removes the
> second-App-ID and 7-day-expiry problem this ticket was written to price.
>
> So do not spend an afternoon here as written. After enrolment the spike is
> simply the first build of the real extension, and "does it install" is
> answered by TestFlight itself. This also unblocks 08.
>
> See the 27 Aug section of `map.md` for the schedule and the de-risking method.


Type: task
Status: open
Blocked by: none

## Question

Front-loaded risk, deliberately first. A Live Activity is a Widget Extension: a
SECOND App ID with its own provisioning profile. The iPhone runs a free-provisioned
7-day sideload through Sideloadly. App extensions are exactly where that setup is
known to be fragile, and free accounts are capped on App IDs.

If an extension will not install, the iOS half of this map cannot be seen, filmed,
or shipped, and it costs 349 dollars to unblock. That is a fact worth having before
a single pixel is designed, not after.

Do the cheapest possible version: a throwaway Widget Extension target that displays
a hardcoded Live Activity with static text. No progress model, no design, no
integration with the ride. The only question is whether it installs and appears on
the lock screen.

Steps, and this is HITL because it needs Xcode and a physical device:

1. Add a Widget Extension target in Xcode. Note the bundle id it generates.
2. Raise the extension's deployment target to 16.1 (the Runner's own target stays
   at 13.0 for now; that decision is ticket 08).
3. Add `NSSupportsLiveActivities` to `ios/Runner/Info.plist`.
4. Declare a trivial `ActivityAttributes` and start the activity from a debug
   button.
5. Build the unsigned IPA the way the current one is built, sideload it, and look
   at the lock screen.

Record in the answer: whether it installed, whether the Live Activity appeared,
the exact failure if not, how many App IDs the account has left, and whether the
7-day expiry applies to the extension separately.

Do NOT preserve this spike. It exists to answer one question and should be reverted
or thrown away. Note the branch it lived on.

Beware: the baseline ride IPA `commute_guardian_unsigned-c9e5bf4.ipa` in
`C:\dev\commute-guardian-logs\baseline-apk\` is the only copy of the build the
verification ride runs on. Do not overwrite it.
