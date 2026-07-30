# 03 - What does ActivityKit allow a local, backend-free app to do?

Type: research
Status: open
Blocked by: none

## Question

The whole iOS half rests on an assumption made while charting: that this app can
update its own Live Activity locally through ActivityKit, with no APNs and no
server, because it holds background location and background audio and is therefore
awake. Verify that assumption against Apple's documentation before anyone designs
against it.

Answer with citations to primary sources (Apple developer documentation, WWDC
session transcripts, ActivityKit release notes). Do not answer from memory.

- Can `Activity.update()` be called from the app process while the app is
  BACKGROUNDED, or only while foregrounded? If backgrounded, under what background
  modes?
- What is the update budget? Is there throttling on frequent local updates, and
  what happens when it is exceeded?
- Maximum lifetime of a Live Activity, and what ends one. A Mumbai local ride can
  run 90 minutes; a Kasara run longer.
- What happens when the app is swiped out of recents on iOS? (On Android the
  30 Jul bench proved the service survives. iOS is a different world and this is
  the equivalent question.)
- iOS 16.1 vs 16.2 vs 17 vs 18 differences that matter to a rider on an older
  phone. Specifically when `ActivityContent` and `staleDate` arrived.
- Does the extension need its own entitlements beyond the Runner's, and does a
  free provisioning profile grant them?
- Is there a Flutter package worth using (`live_activities` or similar), what is
  its maintenance state, and does it force a particular deployment target?

Capture the findings as a markdown file in the repo and link it here.
