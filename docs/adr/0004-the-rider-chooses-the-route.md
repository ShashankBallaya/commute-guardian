# The rider chooses the route, and the alarm stops depending on the plan

Status: accepted (27 Aug 2026)

Reported by a tester from Ghansoli, in her words: there are several ways to reach
one destination, she can go to CST through Vashi or through Thane, and **the
choice of which is hers**. The owner's reaction, recorded because it is the whole
decision in one sentence:

> "It should be onto the rider which route he/she prefer, upto them to suffer or
> gain. We just want to let them know what is the next station on the route and
> wake up before they reach their destination."

`JourneyPlanner` picks ONE route: fewest changes first, then fewest stations
travelled, and the rider is never told another existed. This ADR overturns that
as the last word, and it fixes a safety hole the same premise created.

## Why the original design was SOUND, and what it missed

Minimising changes is right, and it is right for a reason that still stands: a
change at a Mumbai interchange means fighting a crowded footbridge, and riders
care far more about not changing trains than about a stop or two of distance.

What it missed is that **the tiebreak has no information behind it**. When two
routes cost the same number of changes, the planner falls back to counting
stations, and station count is not what a rider optimises. Frequency, crowding,
and whether a fast local runs are what decide it. This app has none of that data
and by locked decision never will: no timetable (12 Jul), no backend, nothing the
rider waits on.

So the tiebreak was never choosing well. It was choosing arbitrarily, and hiding
that it had chosen at all.

## THE MEASUREMENTS THAT SETTLED IT

**Ghansoli, the reported case.** Same origin, four destinations along one stretch
of one corridor:

    Ghansoli -> Byculla       via Thane, change onto Central    20 stations
    Ghansoli -> Chinchpokli   via Thane, change onto Central    19 stations
    Ghansoli -> Masjid        via Vashi, change onto Harbour    19 stations
    Ghansoli -> CSMT          via Vashi, change onto Harbour    20 stations

**The corridor flips halfway down the stretch.** Nothing about the rider changed.
A two-station tiebreak flipped, and the app silently moved her to a different
line for the entire journey.

This is not an edge case. **28 of 127 stations sit on two or more differently
named lines**, so more than a fifth of the network is an interchange. Harbour and
Trans Harbour share 11 stations; Western and Harbour share 9.

**Vasai Road to Kalyan, which is worse, and which killed our own filter.**

    what the app picks    via Dadar    38 stations   1 change
    the MEMU              via Diva     12 stations   1 change

The app rides the full length of Western into Dadar, across the foot overbridge,
and the full length of Central back out. To reach a station 12 stops away on a
direct line.

Re-running the planner with the low-frequency lines REMOVED ENTIRELY produces
**byte-identical output**. The MEMU is never considered for this journey at all,
because `allowLowFrequency: false` finds the Dadar route at one change and the
fallback only ever fires when a station is otherwise UNREACHABLE. Kharbao and
Nilaje get the MEMU. Kalyan never does.

The planner's own comment reads:

> An hourly MEMU is not a route anyone would choose

The owner, who grew up on this network: for Vasai to Kalyan the MEMU is his FIRST
choice, and via Dadar is the fallback he takes when he has missed it. **That
comment is a preference judgement wearing a reality filter's clothes**, and it is
false for exactly the journeys the MEMU exists to serve.

**m-Indicator, which every Mumbai commuter already has, lists six routes for
Vasai to Kalyan including `Vasai Road -> Kopar -> Kalyan, 41 km`.** Route choice
is normal in this market, not exotic, and it lists two-change routes beside
one-change routes with no "recommended" badge.

## THE SAFETY HOLE THE SAME PREMISE CREATED

This is the part that makes this a safety item rather than merely a
correctness one. Read it with the exposure measurement at the end of the
section: the mechanism is total when it fires, and it is not currently
likely to fire for most of the cohort. Both halves are true.

`WakeEscalation` does not target the destination directly. It walks a list of
critical stations: **every interchange the plan requires, then the destination**,
one at a time. The cursor advances only in `_standDown()`, which runs when a
ladder RESOLVES.

So if the plan says "change at Dadar Western" and the rider takes a route that
never goes near Dadar, the Dadar ladder never arms, never stands down, and **the
cursor never reaches the destination. There is no alarm at her stop.**

    planned route has no change   rider takes another line   ALARM STILL FIRES
    planned route has a change    rider takes another line   NO ALARM AT ALL

The first row is safe because `onFix` computes ETA as straight-line distance to
the target over speed, with no chain index in it. The owner was right to
challenge the claim that the wake always breaks; it breaks only when the plan
carried a change.

Station announcements are broken in BOTH rows, because those are chain geofences.

**The mechanism reaches four riders. The probability is not uniform, and
saying otherwise would overstate it.** V3 (Kalyan to Goregaon, change at Dadar),
V5 (Virar to Sion, change at Dadar Western), the Ghansoli reporter (change at
Sanpada) and the owner's own 21 Aug Bandra to Kalyan ride all carry a change, so
the cursor can stick for all four. V2 and V6 have no change in their plan and are
safe outright.

But measured against the alternative each rider actually has:

    V3       alt is 38 stations via Sandhurst Road against 30 via Dadar
             -> UNLIKELY, the alternative is eight stops worse
    V5       alt is 32 stations and TWO changes against 24 and one
             -> NO, clearly worse, she will not take it
    friend   alt is via Thane, WHICH SHE TOLD US SHE TAKES
             -> YES, and she is the reason this was found at all

So this is a real hole that is not currently on fire. The one rider genuinely
exposed is the one whose stated habit differs from our silent guess, which is
precisely the class of rider the whole ADR is about. Build the floor anyway: a
silent, total failure of the one thing the app exists for earns a guard even at
low probability, and the guard is days of work.

## The decision

**The route is the rider's input, not the app's output.** The planner stops being
the thing that decides and becomes the thing that enumerates.

Four layers, in this order. The owner chose 1, 2 and 3 in scope, 4 parked, and
chose to run them SIMULTANEOUSLY with the beta rather than after it.

**1. THE FLOOR: she always gets woken.** When the destination comes inside lead
time, jump the wake cursor straight to it and arm its ladder, whatever the cursor
was doing. Safe because **proximity to the destination proves the remaining
changes are moot**: a rider who slept through a change does not arrive at all,
she ends up down the wrong line. Keep the existing accuracy and speed gates, and
add one this path does not have today: require it on CONSECUTIVE fixes, because
the destination becomes armable during the first leg rather than only the last,
so a single bad fix now has more reach than it used to. Say nothing about the
skipped change; she is at the doors. A corridor check is the thorough mitigation
and lands with layer 2, which builds that maths anyway.

**2. TELL HER SHE IS OFF THE ROUTE.** Not an alarm, a sentence.
`mayResumeUnattended` already measures a fix's distance to the rail corridor,
segment by segment, and is already tested; it was written for the iOS relaunch
lifeline. Pointing it at a live ride is reuse, not new maths. RideHealth already
speaks in this shape with WRONG_DIRECTION. This is the decision restated as
behaviour: we say what we see, she decides.

**3. THE PICKER.** Offer the real routes and let her choose.

  - **No quality ceiling.** Not on changes, not on frequency. Both were the same
    mistake one level up.
  - **Two structural filters only**, because both are correctness and not taste:
    no doubling back, and no revisiting a station.
  - Routes must be **genuinely different**: a different corridor or a different
    interchange, not one ride relabelled.
  - **Frequency is a LABEL, not a filter.** `via Diva, 12 stops, 1 change,
    hourly` beside `via Dadar, 38 stops, 1 change, every few minutes`.
  - Name each route by its interchange chain, the way she said it and the way
    m-Indicator does.
  - Show stops, changes and frequency. NOT kilometres, which is all m-Indicator
    shows and is the least useful number here: 41 km on an hourly MEMU and 41 km
    of fast local are not the same commute. They can afford that. We cannot,
    because our stakes are her stop rather than her curiosity.
  - **Default, do not block.** A hard stop on every multi-route journey punishes
    the majority who always go the same way, and the commit window (`4f0ba15`)
    already catches a mis-tap. Show the default's name where she can see and
    change it.

**4. PARKED: the app re-routes itself** when it sees her on a line she did not
pick. The owner's idea and the right end state. Held because re-planning mid-ride
swaps the chain, the geofences, the overshoot pins and the wake targets while a
ride is live, it needs hysteresis so a tunnel wobble cannot trigger it, and the
new route must be persisted or a resume silently reverts it.

## 27 AUG, LATER: THE M-INDICATOR WAY, AND THE TWO DEFECTS SEPARATED

The owner briefly considered a smarter DEFAULT instead of a picker: break the tie
by preferring interchanges with higher footfall, or "line by line, interchange by
interchange". Testing that against the two known cases split the problem in a way
worth keeping.

**THERE ARE TWO DEFECTS HERE, NOT ONE.**

  A. THE TIEBREAK. Two routes, same number of changes, tie broken on station
     count. This is Ghansoli.
  B. THE EXCLUSION. Low-frequency lines are never searched unless a station is
     otherwise UNREACHABLE. This is Vasai to Kalyan.

**Footfall fixes A and does nothing for B:**

    Ghansoli -> CSMT    app changes at Sanpada (minor)
                        rider wants Thane (one of the biggest)   FIXES IT
    V3, V5, Bandra      app already changes at Dadar (huge)      already right
    Vasai -> Kalyan     app changes at Dadar, THE BIGGEST
                        rider wants Kopar (small)                ENTRENCHES IT

Vasai to Kalyan is not a tiebreak at all. The MEMU is never in the running to be
tied against, so no ranking rule can reach it.

**THE OWNER'S DECISION, and it resolves both at once:**

> "Let's put the judgment on to the rider itself and go the M-indicator way to
> let the user decide which route they prefer even it costs them"

**Showing the routes fixes B as well as A**, because B stops being a ranking
problem and becomes a visibility one. We never have to decide whether an hourly
train is worth it. We show it, labelled hourly, and she decides.

**THE FAST-TRAIN IDEA SURVIVES, DEMOTED.** It is worth recording because it is
better than footfall and the data already exists in the owner's head rather than
in a dataset he would have to source. The real signal is not crowd volume, it is
**whether fast trains stop there**, which is why Thane beats Sanpada and Dadar
beats Parel. It is a short, stable, hand-curated list of about 25 stations. His
own words, already quoted in `journey_planner.dart` from the Parel fix:

> the common thing in Mumbai is to go to the biggest station, because there you
> get both fast and slow

Its job is now much smaller: it decides **which route is highlighted for a rider
who does not look**, not which route she takes. Low stakes, so it can come later
or never.

**ENGINEERING CALLS TAKEN RATHER THAN ASKED**, because they are implementation
and not product. All revisitable:

  - Enumerate routes at the best change count AND best-plus-one. m-Indicator's
    own Vasai list does exactly this: one 1-change route, four 2-change routes,
    then another 1-change route.
  - **Cap the list at six**, which is what m-Indicator showed for the worst case
    we have seen. Not a principle, just a number that matches the reference.
  - Dedupe by the SET OF INTERCHANGES, so one ride relabelled cannot appear
    twice.
  - Sort by stops.
  - Keep the two structural filters: no doubling back, no revisiting a station.

## WHY A PICKER IS NOT A NEW CONCEPT TO TEACH

Buying a ticket on this network already asks "via kahan se", because **the fare
depends on the route**. Every commuter has answered that question at a counter or
in UTS. So the picker is not a new idea being introduced to a rider; it is a
question they already know how to answer, asked by an app that then does
something useful with the answer.

m-Indicator tells them the route. The ticket tells them the price. **Nobody wakes
them on it.** That is the gap this app is in, and the owner put the scope in one
sentence worth keeping:

> "our problem only is to wake them up at the interchange and the destination
> that's it"

That is literally what `WakeEscalation` targets: every interchange the route
requires, then the destination. It also explains why route choice matters at all.
**The route decides where the interchanges are**, and the interchanges are half
of what the app promised to wake them for.

## STORAGE: COMPUTE ON DEMAND, DO NOT SHIP A ROUTE TABLE

Asked directly whether the app can store many permutations of a route. Measured
on the development desktop:

    one plan, cold                       25 ms
    one plan, warm median               1.1 ms
    p90                                  36 ms
    worst seen                           89 ms
    ALL 16,002 ordered station pairs    135 seconds

**A picker showing six routes costs about 200 ms in the worst case**, on a screen
that appears once per ride. Compute them when she asks.

Precomputing every pair is technically fine as a build-time artifact, about two
minutes and a couple of megabytes beside a 13.5 MB clip pack. It buys nothing and
it creates a real hazard: **the station JSON is GENERATED from OSM by
`tool/build_stations.py`**, so a shipped route table becomes a second source of
truth that has to be regenerated in lockstep. Miss that once and the app offers a
route through a station that was renamed. That is exactly what happened when
Dadar was split on 25 Aug and 14 clips went stale in one commit.

**What IS stored is the single route she chose, for the ride she is on.** Small,
and mandatory: without it a kill hands her the other route on resume and wakes
her against a chain she is not on.

## EXPECTED FATE OF LAYER 4

Once the picker exists, self-rerouting loses most of its value, because the main
reason a rider ends up off-route today is that **the app guessed**, and the
picker removes the guessing. What remains is a rider changing her mind mid-ride,
or a diversion, which layer 2 (telling her) probably covers.

Keep it parked and expect never to build it. It has already paid for itself: it
is the reason the chosen route is stored as a first-class thing, which the picker
needs anyway.

## Consequences

**The chosen route must be persisted and survive a resume.** Today the route is
re-derived from origin and destination on every resume and every iOS relaunch, so
a rider who picked via Thane would silently be handed via Vashi after a kill, and
would then be woken against a chain she is not on. This is exactly the trap
`344b1a5` closed for Prabhadevi this morning, and here it is worse: the wake
lands on the wrong chain rather than merely saying the wrong word. **Make the
chosen route a first-class stored thing**, which is also the one cheap thing to
do now for layer 4.

**The default changes for journeys nobody has chosen yet.** Vasai to Kalyan
silently means the 38-station horseshoe today. Once routes are offered, a rider
who taps without reading may get an hourly train. Labels make that visible. They
do not make it impossible.

**Ride logs get harder to read.** "Ghansoli to CSMT" stops naming one chain. The
log must record which route was chosen, the same gap `cceb296` closed today for
the walk across a foot overbridge.

**The planner's low-frequency rule needs revisiting, not deleting.** Falling back
to an hourly line only when a station is unreachable is right for the SEARCH. It
is wrong as the reason a rider never sees the option.
