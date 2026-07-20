"""Generate the full announcement clip pack through Sarvam TTS.

Extends the quality spike (build_sarvam_clips.py, which this imports for the
API plumbing): where the spike generated bare station names, this generates the
FULL PHRASES the app speaks, per station, per language, mirroring the templates
in ride_progress.dart, journey.dart, and wake_escalation.dart. Dynamic
sentences (ETAs, post-call catch-ups, route summaries) are deliberately absent:
they stay device TTS forever, per docs/adr/0001 and the CONTEXT.md glossary.

The English templates are copied VERBATIM from the code. The Hindi and Marathi
templates are new copy written for this pack (the code is English-only today);
audition one station's set before batching all 127.

Run:
  python tool/build_clip_pack.py --station kalyan   # one station + fixed lines,
                                                    # writes audition.html
  python tool/build_clip_pack.py                    # everything (127 stations)

Output: build/sarvam_clips/{lang}/{station}__{kind}.wav, fixed lines under
_fixed__{key}.wav. Existing files are skipped; delete a file to force a retake.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_sarvam_clips import (  # noqa: E402
    LANGS,
    OUT_DIR as SPIKE_DIR,
    STATIONS_JSON,
    load_key,
    synthesize,
)

PACK_DIR = SPIKE_DIR.parent / "sarvam_clips"

MODEL = "bulbul:v3"
SPEAKER = "ritu"

# Per-station templates. {n} is the station name in that language.
# en-IN strings must stay byte-identical to what the code speaks, so a clip can
# replace a device TTS utterance one for one.
TEMPLATES = {
    "en-IN": {
        "approach": "Now approaching {n}.",
        "passed": "You have passed {n}.",
        "overshoot": "You have passed your stop. It is alright. "
            "Please alight here, at {n}.",
        "destination": "You have arrived at your destination, {n}.",
        "wake_checkin": (
            "Your stop, {n}, is next. Tap your earphones, or press the "
            "I am awake button, to show you are awake."
        ),
        "wake_up_stop": "Wake up! Wake up. Your stop, {n}, is next.",
        "wake_up_change": "Wake up! Wake up. Your train change at {n} is next.",
    },
    "hi-IN": {
        "approach": "अगला स्टेशन {n}।",
        "passed": "ट्रेन {n} से आगे निकल गई है।",
        "overshoot": "आपका स्टेशन पीछे छूट गया है। कोई बात नहीं। कृपया यहीं, "
            "{n} पर उतरें।",
        "destination": "आप अपने गंतव्य स्टेशन {n} पर पहुँच गए हैं।",
        "wake_checkin": (
            "आपका स्टेशन, {n}, अगला है। जागे हैं यह बताने के लिए अपने "
            "ईयरफ़ोन को टैप करें, या 'मैं जाग गया' बटन दबाएँ।"
        ),
        "wake_up_stop": "जागिए! जागिए! आपका स्टेशन, {n}, अगला है।",
        "wake_up_change": "जागिए! जागिए! {n} पर आपकी ट्रेन बदलनी है, "
            "वह अगला स्टेशन है।",
    },
    "mr-IN": {
        "approach": "पुढील स्टेशन {n}.",
        "passed": "गाडी {n} च्या पुढे गेली आहे.",
        "overshoot": "तुमचे स्टेशन मागे राहिले आहे. काळजी करू नका. "
            "कृपया येथेच, {n} येथे उतरा.",
        "destination": "तुमचे गंतव्य स्टेशन {n} आले आहे.",
        "wake_checkin": (
            "तुमचे स्टेशन, {n}, पुढे आहे. तुम्ही जागे आहात हे दाखवण्यासाठी "
            "इयरफोनला टॅप करा, किंवा 'मी जागा आहे' बटण दाबा."
        ),
        "wake_up_stop": "उठा! उठा! तुमचे स्टेशन, {n}, पुढे आहे.",
        "wake_up_change": "उठा! उठा! {n} येथे गाडी बदलायची आहे, "
            "ते पुढील स्टेशन आहे.",
    },
}

# Whole-sentence fixed lines with no station name. The English farewell is
# verbatim from geofence_chain_service.dart; good_awake from wake_escalation.dart.
FIXED = {
    "en-IN": {
        "farewell": "Thank you for using Commute Guardian.",
        "good_awake": "Good, you are awake.",
    },
    "hi-IN": {
        "farewell": "कम्यूट गार्जियन इस्तेमाल करने के लिए धन्यवाद।",
        "good_awake": "बहुत अच्छा, आप जाग गए।",
    },
    "mr-IN": {
        "farewell": "कम्यूट गार्जियन वापरल्याबद्दल धन्यवाद.",
        "good_awake": "छान, तुम्ही जागे आहात.",
    },
}

NAME_FIELD = {"en-IN": "name", "hi-IN": "nameHi", "mr-IN": "nameMr"}

# Delivery, not wording: wake lines are spoken faster (urgency, owner's call
# 17 Jul 2026), the overshoot slower (a rider who overslept must not panic on a
# moving train). Everything else uses the API default.
PACE = {
    "overshoot": 0.9,
    "wake_checkin": 1.1,
    "wake_up_stop": 1.15,
    "wake_up_change": 1.15,
}


def clip_jobs(stations: list[dict], langs: list[str] | None = None):
    """Yield (relative_path, text, lang, pace) for every clip in scope."""
    for lang, templates in TEMPLATES.items():
        if langs and lang not in langs:
            continue
        for station in stations:
            n = station[NAME_FIELD[lang]]
            for kind, template in templates.items():
                yield (
                    f"{lang}/{station['id']}__{kind}.wav",
                    template.format(n=n),
                    lang,
                    PACE.get(kind),
                )
        for key, text in FIXED[lang].items():
            yield (f"{lang}/_fixed__{key}.wav", text, lang, None)


def write_audition_page(jobs: list[tuple[str, str, str, float | None]]) -> None:
    rows = "".join(
        f"<tr><td>{lang}</td><td>{rel.split('__')[-1][:-4]}</td>"
        f"<td>{text}</td><td>{'default' if pace is None else pace}</td>"
        f"<td><audio controls preload='none' src='{rel}'></audio></td></tr>"
        for rel, text, lang, pace in jobs
    )
    (PACK_DIR / "audition.html").write_text(
        "<meta charset='utf-8'><title>Clip pack audition</title>"
        f"<h2>Clip pack audition ({MODEL}, {SPEAKER})</h2>"
        "<p>Judge the WORDING as much as the voice: these sentences become "
        "the app's announcement copy in each language.</p>"
        "<table border='1' cellpadding='6'>"
        "<tr><th>Lang</th><th>Kind</th><th>Text</th><th>Pace</th>"
        "<th>Audio</th></tr>"
        f"{rows}</table>",
        encoding="utf-8",
    )


def write_manifests(jobs: list[tuple[str, str, str, float | None]]) -> list[str]:
    """Write one manifest.json per language directory in the pack.

    The app refuses to play any clip a manifest does not vouch for. Matching
    on filename alone is not enough: the station JSON is generated, so a pack
    cut before a name change would keep passing a code-only check while
    naming the wrong station out loud. Recording the exact sentence each clip
    was cut from is what makes the byte-identical rule (ADR 0001) real
    instead of aspirational.

    Derived purely from the templates and the station JSON, so this costs no
    Sarvam credits and never touches the audio.
    """
    per_lang: dict[str, dict[str, str]] = {}
    for rel, text, lang, _pace in jobs:
        stem = pathlib.Path(rel).stem
        if stem.startswith("_fixed__"):
            continue
        per_lang.setdefault(lang, {})[stem] = text

    written = []
    for lang, sentences in per_lang.items():
        out = PACK_DIR / lang / "manifest.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            json.dumps(sentences, ensure_ascii=False, indent=1, sort_keys=True),
            encoding="utf-8",
        )
        written.append(f"{out} ({len(sentences)} clips)")
    return written


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--station", help="single station id: audition mode")
    ap.add_argument(
        "--manifest-only",
        action="store_true",
        help="write manifest.json for each language and exit, synthesizing "
        "nothing. Use this to bless a pack that was cut before manifests "
        "existed; it costs no credits.",
    )
    ap.add_argument(
        "--lang",
        action="append",
        help="limit to a language code (repeatable), e.g. --lang hi-IN. "
        "Added when credits ran short mid-batch: finish one language "
        "without starting the next.",
    )
    args = ap.parse_args()

    data = json.loads(STATIONS_JSON.read_text(encoding="utf-8"))
    stations = data["stations"]
    if args.station:
        stations = [s for s in stations if s["id"] == args.station]
        if not stations:
            sys.exit(f"unknown station id {args.station!r}")

    jobs = list(clip_jobs(stations, args.lang))

    if args.manifest_only:
        for line in write_manifests(jobs):
            print(f"wrote {line}")
        return

    key = load_key()
    fetched = skipped = 0
    for rel, text, lang, pace in jobs:
        out = PACK_DIR / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if out.exists():
            skipped += 1
            continue
        out.write_bytes(synthesize(key, text, lang, MODEL, SPEAKER, pace=pace))
        fetched += 1
        if fetched % 25 == 0:
            print(f"...{fetched} fetched, {skipped} skipped", flush=True)
        time.sleep(0.3)

    if args.station:
        write_audition_page(jobs)
        print(f"audition page: {PACK_DIR / 'audition.html'}")
    for line in write_manifests(jobs):
        print(f"wrote {line}")
    print(f"{fetched} fetched, {skipped} already present, {len(jobs)} total.")


if __name__ == "__main__":
    main()
