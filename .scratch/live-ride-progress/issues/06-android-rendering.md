# 06 - What does it look like on Android?

Type: prototype
Status: open
Blocked by: 02, 04

## Question

The rendering that must ship. 90 to 95 percent of riders see this one and no other.

Build it rough and put it on the 3T. Do not design it in Figma first: a
notification is not a canvas, it is a handful of slots the system owns, and the
fastest way to learn what fits is to post one and look at it. This is the pattern
that has worked every time on this project, most recently on 30 Jul when three
defects invisible to 277 tests were obvious within seconds of looking at a real
screen.

To settle by looking:

- Collapsed vs expanded. What survives in the collapsed row, which is what a rider
  actually sees without pulling the shade down.
- The rail. Android has a native progress bar and the owner asked specifically for
  a slider or rail. Does the native bar carry the meaning, or does the count do the
  work and the bar just decorate?
- The hero. Screen 4 made the stations-remaining count the single most glanceable
  element and that decision held up on the device. Does the notification agree, or
  does the next station win when the rider is standing at a door deciding whether
  to get off?
- Text length under a real 28-station cross-line journey with an interchange. The
  Dadar walk-across instruction is long and this project has overflowed twice
  already by not checking at 1080x1920.
- Coexistence with the actions. Commit `91d52c8` puts "I'm awake" there during an
  alarm and up to three actions during wind-down. The layout must still read with
  those present.

Load `/emil-design-eng` at the START of this, per the standing instruction, and
apply its "should this animate at all" test to any motion.

Link the prototype branch here.
