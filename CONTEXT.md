# Commute Guardian

Commuter companion for suburban rail riders (Mumbai local first). One Travel Mode combining station announcements, a wake escalation for sleeping riders, and periodic pocket reassurance, all delivered as audio through earphones.

## Language

### Ride

**Journey**:
The planned route between an origin and a destination: the station chain, the interchanges it requires, and the overshoot pins. Fully derivable from the station data at any time; it carries no progress.
_Avoid_: trip

**Ride**:
One execution of a journey, from Start Travel Mode to journey end. Its progress exists only while it runs and cannot be recomputed, only reported; a ride can outlive its journey (an overshoot carries the rider past the end of the chain).
_Avoid_: session, trip

**Travel Mode**:
The rider-facing name for a live ride. Used in copy and screen states, not as a code identifier.

### Announcement audio

**Announcement**:
One spoken message delivered during a ride: a station arrival, a wake ladder line, the welcome, or the farewell.

**Dynamic announcement**:
An announcement whose text is composed at runtime (ETAs, post-call catch-up). Always spoken by device TTS; it can never be pre-recorded.

**Clip**:
A pre-generated audio file for one fixed phrase or station name, produced at build time and stitched with other clips at runtime.
_Avoid_: recording, sample, audio asset

**Clip pack**:
The full set of clips for one language, delivered and versioned as a unit. Delivery mechanism is deliberately undecided (see ADR 0001).
_Avoid_: language pack, asset pack

**Device TTS floor**:
The invariant that the on-device TTS engine can speak every announcement by itself, with no network and no downloaded files. Clips are an enhancement layered on top; a missing, partial, or corrupt clip pack must never block or degrade Travel Mode below this floor.
_Avoid_: fallback TTS (the floor is the primary path until clips exist, not a fallback)
