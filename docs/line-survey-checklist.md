# Line survey checklist

Collect real 1 Hz GPS for all 127 stations, one line per sector, before Phase 2
completes. Owner rides personally; no synthetic track generator and no tester
recruitment is planned for this.

Decided 28 Jul 2026. Rationale, so it does not get relitigated on a tired
evening:

- **1 Hz, not adaptive sampling.** Fixes can be thrown away later in replay
  (that is exactly how the 78 percent adaptive-sampling analysis was done);
  they can never be added back. Riding with sampling on would also make every
  missed fence ambiguous between the line's geometry and the sampling.
- **Power bank, not code.** Western is a 4 hour single ride, about 40 percent
  of the 3T's battery. A power bank costs about 1000 rupees and solves it
  outright.
- **3T, not the iPhone.** Half the drain, and logs pull straight off over adb
  instead of arriving as uploads.

The survey pays a dividend beyond coverage: a 1 Hz corpus across all 11 lines
is the validation set adaptive sampling currently lacks (it was tuned on 8 logs
from one corridor), so the optimisation becomes decidable on evidence.

## Before each ride

- [ ] 3T charged, power bank charged, cable packed
- [ ] App is on a known commit; write the short SHA in the row below
- [ ] Clip pack present (892 files in `clips/en-IN`) and permissions granted
- [ ] `adb shell svc power stayon true` not needed on battery, but confirm the
      phone is not on a battery saver profile that throttles location
- [ ] Note the train type before boarding: FAST or SLOW. This is the single most
      useful annotation, because fast trains pass skipped stations at line speed
      (22 m/s measured at Thakurli) and that is the worst case for every fence.

## During the ride

- [ ] Start Travel Mode with the real origin and destination for that leg
- [ ] Screen locked, phone pocketed, earphones in, for at least part of the leg
- [ ] Note by hand anything the app got wrong, with the clock time: a missed
      announcement, a wrong station name, an announcement that arrived late
- [ ] Note any long tunnel, cutting, or dense-built stretch (candidate GPS gaps)

## After each ride

- [ ] `adb pull /sdcard/Android/data/com.ballshank.commute_guardian/files`
- [ ] Rename the log `YYYYMMDD-<line>-<origin>-<destination>-<fast|slow>.log`
- [ ] Replay it: `dart tool/replay_ride.dart --origin <id> --destination <id>`
      (always pass both explicitly, the default plans a different journey)
- [ ] Record battery start and end percentages in the row
- [ ] Any station that missed a fence goes on the defect list, not the ride list

## The sectors

Ordered by what they probe, not by convenience. The top three carry every tight
gap in the network; the bottom five are wide-spacing lines where the geometry
analysis predicts the full 1000 m fence and the full 90 s wake floor, so they
are coverage, not risk.

| # | Line | km | ~h | Stns | Tightest gap | What it probes | Done | Commit | Batt |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Central Main: CSMT - Kalyan | 56 | 1.7 | 26 | 729 m Chinchpokli-Currey Road | The dense southern trunk: 5 sub-1200 m gaps, Masjid, Sandhurst Road, Currey Road. Also the only line already part-ridden, so it cross-checks the new geography against 9 known-good rides. | ☐ | | |
| 2 | Harbour: CSMT - Panvel | 51 | 1.5 | 25 | 909 m Sandhurst Rd-Dockyard Rd | Worst gap density in the network: 7 sub-1200 m gaps. Reay Road, Cotton Green, Dockyard Road, Tilak Nagar, Chembur. | ☐ | | |
| 3 | Western: Churchgate - Dahanu Road | 135 | 4.0 | 37 | 784 m Grant Rd-Mumbai Central | Longest ride and the battery test. Carries Mumbai Central (the 0.5 s heads-up), Marine Lines, Charni Road, and Dadar Western + Matunga Road. Split into two sectors if 4 h is too much in one go. | ☐ | | |
| 4 | Harbour: CSMT - Goregaon | 29 | 0.9 | 18 | 909 m Sandhurst Rd-Dockyard Rd | 4 tight gaps; overlaps Harbour trunk, so ride it only if sector 2 flagged anything. | ☐ | | |
| 5 | Trans-Harbour: Thane - Panvel | 35 | 1.0 | 15 | 1312 m Nerul-Seawoods | Wide spacing, coverage only. | ☐ | | |
| 6 | Central: Kalyan - Kasara | 67 | 2.0 | 12 | 2990 m Kalyan-Shahad | Widest spacing on the network. Coverage only. | ☐ | | |
| 7 | Central: Kalyan - Karjat | 50 | 1.5 | 10 | 1877 m Vithalwadi-Ulhasnagar | Coverage only. Ghat section, worth noting GPS quality. | ☐ | | |
| 8 | Vasai Road - Diva | 48 | 1.4 | 8 | 3493 m Dativali-Kopar | Coverage only. Sparse, rural, good GPS-gap candidate. | ☐ | | |
| 9 | Diva - Panvel | 28 | 0.8 | 7 | 1875 m Diva-Dativali | Coverage only. | ☐ | | |
| 10 | Uran: Nerul - Uran | 25 | 0.7 | 9 | 1312 m Nerul-Seawoods | Coverage only. Newest line, most likely to have stale OSM data. | ☐ | | |
| 11 | Trans-Harbour: Thane - Vashi | 18 | 0.5 | 9 | 1171 m Sanpada-Vashi | Shortest. Coverage only. | ☐ | | |

Totals: about 540 km and 16 h one way, 1080 km and 32 h with return legs.
Distances are straight-line station-to-station scaled by 1.10, calibrated
against the owner's known CSMT-Kalyan figure of 56 km. Hours assume the slow
local rate implied by that same datum (56 km in 1h40).

## The one journey that is not a line

Ride this as its own sector, because it is the only route that exercises the
Dadar walk interchange and it is the reason `2d8e39a` exists:

- [ ] **Churchgate to Kalyan**, changing at Dadar. Alight Dadar Western, cross
      the bridge, board Dadar Central. Watch that the interchange alarm SURVIVES
      arrival at Dadar Central (the two halves are 207 m apart behind 450 m
      fences, and before `2d8e39a` the second half hard-stopped the alarm for
      the first). The ceiling should now be Matunga.

## Known desk findings the survey should confirm or refute

From the 28 Jul geometry analysis over all 8001 station pairs:

1. **Fence overlap is not a network-wide problem.** Only 4 overlapping pairs
   exist, all Central/Western twins on parallel lines (Dadar, Parel/Prabhadevi,
   Currey Road/Lower Parel, Matunga/Matunga Road). They never share a line and a
   cross-Dadar journey takes one from each pair, so they cannot collide in a
   chain. Only the declared Dadar pair does, and that is fixed.
2. **The wake is protected everywhere by time, not geometry.** The ladder arms
   on the first of "arrival at the previous station" or "ETA under 90 s", and
   the ETA leg does not care about station spacing. The survey should show a
   check-in about 90 s out even where stations are 729 m apart.
3. **The approach heads-up degrades at 23 stations**, worst at Mumbai Central
   (0.5 s at 22 m/s), because the ping is gated on the nearest station and so
   can never fire further out than half the inbound gap. Judged cosmetic, since
   the ladder already spoke 90 s earlier. Sector 3 is where to check that
   judgement against a real rider's experience.
