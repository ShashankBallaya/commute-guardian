# UI punchlist

Opened 11 Aug 2026 from the owner's device review on both phones, after the
first iOS build that could actually be ridden. Grouped by screen. Each item says
whether a device is needed to judge it.

**Load `/emil-design-eng` before starting any of these**, per the standing
instruction: at the start of the work, not as a review afterwards.

---

## Screen 4, Travel Mode

### 1. The wake toggle does nothing. DECIDE BEFORE POLISHING.

`ride_orchestration.dart:53`: "NOTHING CONSUMES IT YET. The wake ladder still
fires on its locked rules, and this must not quietly become a second way to
change leadTimeS."

So "Last 2 stations / Only destination" is a prominent control on the live ride
screen with no effect on the ride. And by the locked monetization design the
pre-warning DISTANCE is exactly what Guardian Plus sells, with two stations as
the free default. **Owner's call: wire it or remove it.** Polishing a control
that changes nothing is the wrong order.

### 2. Tapping the toggle does not redraw the screen. THE FLAG IS NOT THE STATE, again.

`onWakeChoiceChanged` calls `setState` on the HOST state
(`ride_orchestration.dart:711`), but Screen 4 is built inside a
`MaterialPageRoute` builder wrapped in a `Consumer`. A host's `setState` does not
rebuild a pushed route, and the `Consumer` only rebuilds when `liveRideProvider`
changes. So the field changes and the screen does not, until the next progress
event happens to arrive. Reported as "I can't toggle between Only destination and
Last 2 stops", which is what it looks like from the outside.

FOURTH INSTANCE of this pattern (the wind-down deadline, the arrival, the wake
rung, now this). The fix is the same shape every time: the state has to live
where the screen is watching.

No device needed. It is testable: pump Screen 4 inside a route, tap, expect the
selection to move without any provider changing.

### 3. The wake card is cramped, and the tap targets shrink with it

Owner: "isn't perfectly spaced looks very unaesthetic". `_WakeCard` puts the
label and the toggle in two competing `Flexible`s with a 10 px gap, and the
toggle sits in a `FittedBox(scaleDown)`, so on a narrow phone the control is
scaled DOWN and its two segments go under the 48 dp floor. Judge on the 3T, and
measure rather than infer, per the button-sizing rule.

### 4. The "Wake-up mode active" shield chip is misaligned

Owner: "the Shield is not perfectly aligned need some UI treatment". The icon
sits against two lines of text and the chip crowds the "N stations to
DESTINATION" heading beside it. Not examined in code yet. Device needed.

---

## Screen 1, Home

### 5. Two treatments for the same action

`Start your first journey` (empty state) is **crimson**; `New journey` (list
state) is **white**. Both open the picker. A rider sees only one at a time, so it
is not visible side by side, but it is two languages for one action, and by
`Palette`'s own rule crimson is reserved for starting or ending a JOURNEY, which
opening a picker is not. Also the crimson one is mislabelled: it starts nothing.

No device needed. Owner's call on which way it resolves.

---

## Carried over from the apple-design pass, agreed and never done

### 6. The wake alert swallows repeated back presses

`_refusePop` early-returns while nudging, so a second back press within the nudge
does nothing at all. A half-asleep rider pressing twice deserves the same answer
twice.

### 7. `TypeScale` has no tracking axis

Hero at 46 and display at 22 read loose. Roughly -0.9 and -0.4 wanted. Judge on
the 3T.

(`SlideToStart`'s velocity and rubber-banding items are CLOSED: the widget was
retired on 11 Aug and a ride now starts with a tap on every screen. Deleting beat
fixing.)

---

## Settings

### 8. The vibration toggle is a dead control on iOS

iOS forbids background haptics, so `PulseOutput.buzz` returns at its first line
there. The switch should be hidden on iOS rather than offered. Confirmed by a
10 Aug iPhone ride log that claimed "with vibration" for a buzz that could not
happen; the log line is fixed, the control is not.

---

## Copy, not layout

### 9. Hindi and Marathi speak in the first person, and it reads too casual

Owner heard it for the first time on the 10 Aug iPhone ride: `बताऊँगा` is a man
promising you something, where a railway announcement states that something will
be announced. Only TWO lines in each language do this, both in
`lib/services/spoken_copy.dart`:

- the welcome: `मैं रास्ते का हर स्टेशन बताऊँगा` / `मी वाटेतील प्रत्येक ...`
- train held up: `मैं आपके स्टेशन पर नज़र रखे हूँ` / `मी तुमच्या स्टेशनवर लक्ष ...`

`नज़र रखे हूँ` is also not standard. Everything else already uses polite `आप`
forms and imperatives, which read as instructions rather than as a friend
talking.

**Owner supplies the wording**, being the native speaker and this being his
market. No clips are involved: none of these phrases appear in
`build_clip_pack.py`, and `spoken_copy.dart` is by design the file of sentences
with no recorded audio. The station announcements in
`announcement_templates.dart` are a separate matter and were auditioned 17 Jul.

---

## Closed by measurement, kept so they are not re-reported

- **"You are here" appearing after a station you are standing at.** FIXED
  `ef5b4ab`, 9 Aug. The 11 Aug screenshot that appeared to show it was taken
  805 m from Shahad (measured from the ride log's own fix against the station
  data), which is outside any fence, so "between Shahad and Kalyan" was correct.
  Standing on a platform names the station on one row. Tested, and the guard was
  mutation-tested twice.
- **The 9 Aug X post's chain showing Badlapur and "You are here" as two rows.**
  Same fix; that photo predates it by six hours.
- **Settings promising "a quiet sound through your earphones".** Fixed 11 Aug: the
  chime has always used the speaker when there are none, and the copy now says
  so before a rider switches it on.
