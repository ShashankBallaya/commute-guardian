# 05 - Which moments earn the rider's attention, and which update silently?

Type: grilling
Status: open
Blocked by: 02

## Question

A surface that updates 30 times a ride has 30 chances to be annoying. This is the
line between a feature riders love and one they turn off, and it is a design
decision, not a technical one.

Every state change in the model (ticket 02) falls into one of three buckets, and
this ticket assigns each one:

1. **Silent update.** The surface changes; nothing draws the eye. Most station
   crossings belong here.
2. **Glanceable change.** Something visibly shifts so a rider already looking sees
   it, but no sound and no heads-up.
3. **Demands attention.** Sound, heads-up, or the screen waking.

Constraints already locked that this must respect:

- The wake alarm is the ONLY thing in the app that is allowed to be loud, and it
  has its own escalating ladder. Nothing here may compete with it or dull it.
- The rider is often asleep. That is the entire premise of the product. A surface
  that pings on every station defeats the thing the app exists to do.
- The rider is often listening to music through earphones. Audio ducking has been
  the single hardest problem in this project. Anything here that makes noise
  inherits all of it.
- `onlyAlertOnce: true` is set today, which is the current answer by default:
  everything is silent. Confirm or change it deliberately rather than inheriting.

Also settle: does the surface do anything DIFFERENT in the last two stations, the
window the wake ladder already treats specially? And is arrival at the destination
a state on this surface at all, or does it hand off entirely to the Arrival screen
(Screen 5, approved 09 Jul, still unbuilt)?
