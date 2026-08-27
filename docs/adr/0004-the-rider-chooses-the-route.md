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

This is the part that makes this urgent rather than merely correct.

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

**Half the servable cohort is exposed today**: V3 (Kalyan to Goregaon, change at
Dadar), V5 (Virar to Sion, change at Dadar Western), the Ghansoli reporter
(change at Sanpada), and the owner's own 21 Aug Bandra to Kalyan ride.

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
