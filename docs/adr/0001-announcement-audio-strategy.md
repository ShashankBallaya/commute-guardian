# Device TTS is the floor; cloud TTS only as a build-time clip factory

Status: accepted (15 Jul 2026)

Announcement quality in Hindi and Marathi is limited by device TTS voices, and Sarvam's cloud TTS is markedly better for Indic languages. We decided that live, in-ride cloud TTS is permanently rejected: it breaks the locked no-backend decision, puts a network call inside the offline wake path (the one failure the product exists to prevent), and attaches metered per-character cost to free users. Sarvam may be used only as a build-time clip factory: generate clips for the closed set of station names (assets/stations already carries Devanagari names) and fixed phrases once, on the dev machine, and stitch them at runtime. Device TTS remains the load-bearing floor for every announcement (see CONTEXT.md, "Device TTS floor"); dynamic sentences are always device TTS.

## Considered options for clip pack delivery (deferred)

Delivery is deliberately undecided until a quality spike proves the clips are worth shipping.

- Store-native hosting (Play Asset Delivery + On-Demand Resources): rejected for now. Two platform-specific implementations, clip fixes gated behind store releases, and untestable before the app has store distribution (current iPhone builds are sideloaded).
- Static bucket (Cloudflare R2, versioned zip + manifest): lead candidate if delivery is ever built. One implementation for both platforms, clip updates without a release, effectively free at our scale. Adopting it would amend the no-backend decision and needs its own ADR.
- Bundling all languages in the app: rejected. **The size estimate in this line was wrong by an order of magnitude and is corrected here (10 Aug 2026): the generated packs measure 125 MB for en-IN (892 files) and 154 MB for hi-IN (864 files) as WAV, not "8 to 15 MB across three languages".** Even heavily compressed that is tens of MB against a 13 MB iOS app, so the rejection stands and stands harder. Recorded rather than quietly edited, because this was the number the decision rested on.

## Delivery, decided 19 Aug 2026: bundle the pack in the app

**We bundle. The open question turned out to be a FORMAT question, not a delivery question.**

Every option above was weighed against 125 MB, and the rejection of bundling was correct at that size. The packs are raw WAV, 22.05 kHz mono 16-bit, because that is what the factory wrote and nothing ever asked it for anything else. Re-encoded to 32 kbps mono AAC the English pack measures **13.5 MB, a 9.5x reduction, measured and not estimated**. At that size the argument that killed bundling simply stops applying: no asset pack, no bucket, no versioned zip, no second implementation per platform, and no amendment to the no-backend decision.

What forced the question was the closed beta rather than any quality doubt. The pack arrived by `adb push` into the app's external files directory, and on Android 11+ that directory cannot be reached without a laptop. Two phones in this project have a pack. **No volunteer could ever be given one**, so every beta tester would have ridden on the device TTS floor and paid its 500 to 900 ms of cold start at every station, and would have heard the wake ladder, the sentence this product exists to say, in exactly the voice this ADR's clip factory was built to replace.

The decisions that do NOT change:

- Device TTS stays the load-bearing floor. All four fallbacks stay exactly as they were, and a bundled pack means a rider can lose the nicer voice and can never lose the information.
- Dynamic sentences stay on TTS. Bundling changes how the pack arrives, not which sentences a clip may replace.
- Sarvam stays a build-time factory. Nothing about this puts a network call in a ride.

What it costs, stated plainly:

- About 13.5 MB on every rider's download, and 13.5 MB again on disk, because the pack is copied out of the assets at first launch rather than played from them. That copy is what keeps the ride's audio path, which has been ridden, untouched.
- A clip fix now needs an app release. The static bucket was the option that avoided that, and it is the option to revisit if clip churn ever becomes real. `adb push` still overrides the bundled pack, so a re-cut clip can be tried on a phone without a rebuild.
- Hindi and Marathi are NOT bundled, because neither has a usable pack: hi-IN has 864 clips, no manifest, and templates that moved under `f0ad04a`; mr-IN has 9. The Settings picker is locked to English and shows both as coming soon, which is an honest statement of the same fact. Bundling all three at this format would be about 31 MB, so size is no longer what stands in the way.

## The bad clips this work found, 19 Aug 2026

Nine clips of 889 carry more audio than their sentence, and are dropped from the bundled manifest by `tool/build_clip_assets.py`. A dropped key falls to device TTS speaking the identical sentence, so the cost is one line in the old voice.

The 16 Aug sweep, run after "gibberish after Vidyavihar" was heard on both legs of a real ride, compared each clip against its kind's mean and looked only at the approach clips. It found one of the nine. Fitting duration against sentence length, then subtracting each kind's median, separates all nine cleanly: **`jogeshwari__wake_checkin` carries 7.6 extra seconds and `tilak_nagar__wake_up_stop` 3.3, and both are wake ladder lines.** Re-cutting them through the factory wins them back; until then nothing broken plays.
