# 07 - What does the Live Activity look like on the lock screen?

Type: prototype
Status: open
Blocked by: 01, 02, 03

## Question

The rendering the owner wants to exist because nobody has built it for this
network. Lock screen only: the Dynamic Island is explicitly out of scope for this
map.

Blocked on 01 for a reason. If an extension will not sideload, this ticket cannot
be looked at, only imagined, and imagining a surface is how this project has
produced its worst work.

To settle by looking:

- The lock-screen layout at its real size, which is small and wider than it is
  tall.
- What the compact leading and trailing slots show, since they are declared in the
  same widget even with the Island out of scope, and a rider on a non-Pro phone
  never sees them.
- Whether the layout is a translation of the Android one or its own thing. Cheaper
  and more coherent if it is the same information in the same priority order, but
  SwiftUI is a different medium and the honest answer may be no.
- `staleDate` behaviour: what the surface says when the app has not updated it for
  a while, which on a rail line means a tunnel, a dead battery saver, or a phone
  the OS has quietly frozen. A Live Activity showing a confidently wrong station is
  worse than one admitting it is stale.
- How it ends. What the rider sees after arrival, and for how long.

The glass surface language, the palette and the type scale are all locked and
documented; this must read as the same app. Load `/emil-design-eng` at the start.

Note: this is SwiftUI, which is outside the owner's stated comfort zone (JS,
frontend, and now Dart). Budget for that, and prefer a small hand-written widget
over a package that hides it.
