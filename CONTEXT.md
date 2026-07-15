# Commute Guardian

Commuter companion for suburban rail riders (Mumbai local first). One Travel Mode combining station announcements, a wake escalation for sleeping riders, and periodic pocket reassurance, all delivered as audio through earphones.

## Language

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
