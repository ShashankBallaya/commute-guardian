# 10 - What defines the approach phase, and does this surface become the WakeChoice toggle's first consumer?

Type: grilling
Status: open
Blocked by: none

## Question

Surfaced by resolving ticket 02. The accepted design defines the `approach` phase
as "2 or fewer stations remaining, matching the wake ladder's window". That window
is not fixed. It is the rider's own choice on Screen 4: `WakeChoice.lastTwoStations`
or `WakeChoice.onlyDestination`. So a rider who picked "Only destination" would see
a passive surface announcing an approach that the ladder is not going to act on,
which is the surface promising something the app will not do.

Three ways out, and this ticket picks one:

1. **`phase` reads the rider's choice.** `approach` means "the ladder is about to
   act", which is 2 remaining for one setting and 1 for the other. Honest, and it
   makes the surface and the alarm agree by construction.
2. **`approach` is defined without reference to the ladder at all.** It becomes a
   pure "you are nearly there" signal at a fixed distance, and the fact that the
   ladder happens to fire nearby is a coincidence the model does not encode.
3. **There is no `approach` phase.** The surface shows `active` until `arrived`,
   and only the alert flags mark the endgame.

## The larger thing hiding in this

Option 1 would make the passive surface **the first actual consumer of the
`WakeChoice` toggle**, which has been reporting a choice that nothing reads since
29 Jul. It is one of the owner's seven open decisions (`phase-2-status`, item 6).

That has consequences beyond this map and they must be weighed here:

- The toggle is the **Guardian Plus surface** per the locked monetization design:
  free fires the pre-warning earlier, Plus sells the CHOICE, never adequacy. If
  the choice starts driving a visible surface, check it does not accidentally
  become a paid difference in what the rider can SEE rather than choose.
- The toggle must **never become a second way to change `leadTimeS`**, which is
  locked at 90 s.
- Whatever this decides, the choice has to reach the service isolate, which today
  it does not. That is additive bridge work (a new `saveData` key and payload),
  cheap, but it is real and it belongs in whichever phase ticket 09 assigns.

Consult the locked monetization design before answering.
