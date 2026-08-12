# An iPhone DOES vibrate from a locked, pocketed phone

Status: accepted (12 Aug 2026)

CLAUDE.md locks two sentences that a measurement on 11 Aug 2026 has now falsified:

> "iOS forbids background haptics but permits background audio, same as
> navigation apps."
> "Haptics are an Android-only bonus layer."

They are wrong as written. `kSystemSoundID_Vibrate` fired 7 times out of 7 on the
owner's iPhone with the screen locked and the phone in a pocket, at the pulse
cadence of 45.0 seconds. Ride log `559de451`. The call travels service isolate ->
`sendDataToMain` -> `media_ack` channel -> `AudioServicesPlaySystemSound`, the
same hop the wake ladder's tone already uses.

## Why the original premises were SOUND, and what they missed

Neither sentence was careless. Both modern haptics APIs behave exactly as the
locked decision said:

- `CHHapticEngine` stops when the app leaves the foreground.
- `UIFeedbackGenerator` is foreground-only by design.
- There is no entitlement to ask Apple for, and the iOS alarm apps that appear to
  vibrate in the background are either playing background AUDIO (which this app
  already does) or firing a local notification that the SYSTEM vibrates for.

What the premises missed is that `AudioServicesPlaySystemSound` is not a haptics
API at all. It is the oldest vibration call on the platform, it predates the
Taptic Engine, and it is governed by neither of the frameworks above. That is why
reasoning could not settle this and a phone had to answer it.

## What this decision changes

**"Haptics are an Android-only bonus layer" is struck.** The correct statement is
narrower and is now the rule:

> **Audio remains the PRIMARY channel on both platforms. Vibration is a second
> channel available on both platforms, in different shapes: Android controls
> duration and pattern, iOS gets one fixed buzz and can vary only COUNT and
> CADENCE.**

Two things become permissible that were refused before:

1. **The wake ladder may vibrate on iOS.** `WakeAlertOutput.vibrate` early-returns
   on `!Platform.isAndroid` quoting the dead premise. This is the valuable one: a
   rider asleep past their station with the phone in a pocket is the product, and
   until now iOS had exactly one channel to reach them with.
2. **Pocket Pulse's iOS buzz stops being a bench and becomes a feature.**

## What the field added the same day (12 Aug 2026, four benches)

The decision above was made from a desk bench. Four wake-ladder benches on the
owner's iPhone that evening, all archived in
`commute-guardian-logs/bench-2026-08-12/`, moved three things from reasoned to
measured:

- **The ladder vibration is felt in a pocket during a live ride**, not only in a
  standing bench. Log `152247`: three bursts at rungs 2, 3 and 4, all three felt.
- **THE FIRST GAP WAS WRONG AND THE OWNER'S LEG FOUND IT.** At 400 ms he felt TWO
  buzzes where three were requested. `kSystemSoundID_Vibrate` runs roughly 400 ms,
  so the second request arrived while the motor was still going and iOS either
  dropped it or ran the two together. At 800 ms he felt three. This is the
  practical shape of "no duration control": the app cannot ask how long a buzz
  lasts, so it must leave room for one it cannot measure.
- **Cancel on ack works on hardware.** Log `164731`: burst starts 16:48:31.62,
  ack from the earphone media button at 16:48:32.87 (between buzz 2 and buzz 3),
  and `WAKE buzz burst cancelled after 2 of 3.` logged at 16:48:33.23, which is
  the moment buzz 3 was due. The rider reported pressing at the second buzz. The
  first test written for this feature is now answered by a leg and not only by a
  unit test.

**And the ride log could not be read at first, which is the lesson to keep.**
`vibrate()` logged nothing on the iOS path, so the first bench fired three bursts
and left no trace of any of them: "he felt two" could not be checked against what
was asked for. That is the 10 Aug rule in mirror image, where a log claimed an
output that never happened. Every burst now logs its count and its spacing, and a
cancelled burst logs the partial count, which is what made the cancel provable at
all.

## What it does NOT licence

Recorded deliberately, because a single measurement is being used to overturn a
founding decision:

- **No intensity or duration control on iOS.** One buzz, fixed. An escalating
  ladder cannot escalate on iOS by getting stronger; it can only get DENSER.
- **The rider can still defeat it.** Settings has switches for system vibration
  and for silent-mode haptics, and this call respects them. It is a bonus channel
  and must never be the only one carrying a wake.
- **Battery cost is unmeasured.** The 45 second pulse ran for one bench, not a
  ride.
- **One phone, one iOS version.** Reports of this call are version-dependent,
  which is the whole reason a bench existed. A future iOS may take it away
  silently, so nothing may DEPEND on it and every failure path must stay audible.
- **The Settings vibration switch stays hidden on iOS for now** (punchlist item 8,
  closed 11 Aug). It offers control over the PULSE buzz; re-offering it is a
  separate decision, and per `substring-guard-bug` the platform guard must state
  the constraint it has rather than an allow-list.

## The rule the bench itself established, and it stays

The ride log must never claim a channel that was not even attempted. The 10 Aug
guard caught the first version of this change un-gating the claim outright, which
would have reintroduced exactly the false "PULSE every 45s, with vibration" line
it exists to stop. `_pulseVibrate` is a claim about a REQUEST, never about a felt
buzz, and iOS attempts are logged separately so a ride log can be read either way
afterwards.

## Consequences

- CLAUDE.md's Travel Mode paragraph must be edited to the narrower rule above.
- `wake_alert_output.dart` gains an iOS path, and its FIRST test is
  cancel-on-ack: a burst that outlives the ack buzzes at a rider who already said
  they are awake.
- The one honest summary of the platform split is now: **iOS is weaker at
  vibration, not incapable of it.**
