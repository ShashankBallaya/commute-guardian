# Device TTS is the floor; cloud TTS only as a build-time clip factory

Status: accepted (15 Jul 2026)

Announcement quality in Hindi and Marathi is limited by device TTS voices, and Sarvam's cloud TTS is markedly better for Indic languages. We decided that live, in-ride cloud TTS is permanently rejected: it breaks the locked no-backend decision, puts a network call inside the offline wake path (the one failure the product exists to prevent), and attaches metered per-character cost to free users. Sarvam may be used only as a build-time clip factory: generate clips for the closed set of station names (assets/stations already carries Devanagari names) and fixed phrases once, on the dev machine, and stitch them at runtime. Device TTS remains the load-bearing floor for every announcement (see CONTEXT.md, "Device TTS floor"); dynamic sentences are always device TTS.

## Considered options for clip pack delivery (deferred)

Delivery is deliberately undecided until a quality spike proves the clips are worth shipping.

- Store-native hosting (Play Asset Delivery + On-Demand Resources): rejected for now. Two platform-specific implementations, clip fixes gated behind store releases, and untestable before the app has store distribution (current iPhone builds are sideloaded).
- Static bucket (Cloudflare R2, versioned zip + manifest): lead candidate if delivery is ever built. One implementation for both platforms, clip updates without a release, effectively free at our scale. Adopting it would amend the no-backend decision and needs its own ADR.
- Bundling all languages in the app: rejected. **The size estimate in this line was wrong by an order of magnitude and is corrected here (10 Aug 2026): the generated packs measure 125 MB for en-IN (892 files) and 154 MB for hi-IN (864 files) as WAV, not "8 to 15 MB across three languages".** Even heavily compressed that is tens of MB against a 13 MB iOS app, so the rejection stands and stands harder. Recorded rather than quietly edited, because this was the number the decision rested on.
