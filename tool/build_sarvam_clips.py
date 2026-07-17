"""Sarvam TTS quality spike: generate station-name clips and listen.

Per docs/adr/0001, Sarvam is a build-time clip factory only. This script is the
QUALITY SPIKE, not delivery: it synthesizes a curated set of tricky station
names in Hindi and Marathi through Sarvam's TTS API, saves the WAVs under
build/sarvam_spike/ (gitignored), and writes a listen.html player page so the
owner can audition every clip and judge whether the quality beats device TTS.
Nothing here ships in the app and nothing downloads on a device.

API key, in order of preference (never commit a key):
  1. SARVAM_API_KEY environment variable
  2. tool/.sarvam_key file (gitignored), the key on the first line

Run:  python tool/build_sarvam_clips.py [--model bulbul:v3] [--speaker NAME]

Existing output files are skipped, so reruns only fetch what is missing.
Delete build/sarvam_spike/ (or a file) to force regeneration.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATIONS_JSON = ROOT / "assets" / "stations" / "mumbai_suburban.json"
OUT_DIR = ROOT / "build" / "sarvam_spike"
KEY_FILE = pathlib.Path(__file__).resolve().parent / ".sarvam_key"

API_URL = "https://api.sarvam.ai/text-to-speech"

# The spike set: the owner's Central Main corridor plus names device TTS is
# most likely to mangle (retroflex L, aspirates, anglicized spellings).
SPIKE_STATION_IDS = [
    "kalyan",
    "thane",
    "thakurli",
    "dombivli",
    "kopar",
    "diva",
    "mumbra",
    "shahad",
    "ambivli",
    "titwala",
    "khadavli",
    "vasind",
    "asangaon",
    "kasara",
    "ulhasnagar",
    "vithalwadi",
    "ghatkopar",
    "vikhroli",
    "chinchpokli",
    "sandhurst_road",
]

LANGS = [
    ("hi-IN", "nameHi"),
    ("mr-IN", "nameMr"),
]


def load_key() -> str:
    key = os.environ.get("SARVAM_API_KEY", "").strip()
    if not key and KEY_FILE.exists():
        raw = KEY_FILE.read_bytes()
        # Tolerate however Windows wrote the file (Notepad UTF-8 BOM,
        # PowerShell redirect UTF-16).
        if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
            text = raw.decode("utf-16")
        elif b"\x00" in raw:  # UTF-16 without a BOM
            text = raw.decode("utf-16-le")
        else:
            text = raw.decode("utf-8-sig")
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        key = lines[0] if lines else ""
    if not key:
        sys.exit(
            "No API key. Set SARVAM_API_KEY or put the key on the first line "
            f"of {KEY_FILE} (gitignored). Keys: https://dashboard.sarvam.ai"
        )
    return key


def synthesize(
    key: str,
    text: str,
    lang: str,
    model: str,
    speaker: str,
    pace: float | None = None,
) -> bytes:
    body = {
        "text": text,
        "target_language_code": lang,
        "speaker": speaker,
        "model": model,
    }
    if pace is not None:
        body["pace"] = pace
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "api-subscription-key": key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        sys.exit(f"Sarvam API error {e.code} for {text!r} ({lang}): {detail}")
    return base64.b64decode(payload["audios"][0])


def write_listen_page(rows: list[dict], model: str, speaker: str) -> pathlib.Path:
    cells = []
    for r in rows:
        players = "".join(
            f'<td><audio controls preload="none" src="{r[lang]}"></audio></td>'
            for lang, _ in LANGS
        )
        cells.append(f'<tr><td>{r["name"]}</td>{players}</tr>')
    page = (
        "<meta charset='utf-8'><title>Sarvam spike</title>"
        f"<h2>Sarvam clips: {model}, speaker {speaker}</h2>"
        "<p>Judge each against what device TTS makes of the same name.</p>"
        "<table border='1' cellpadding='6'>"
        "<tr><th>Station</th><th>Hindi</th><th>Marathi</th></tr>"
        + "".join(cells)
        + "</table>"
    )
    out = OUT_DIR / "listen.html"
    out.write_text(page, encoding="utf-8")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="bulbul:v3")
    ap.add_argument("--speaker", default="ritu")
    args = ap.parse_args()

    key = load_key()
    data = json.loads(STATIONS_JSON.read_text(encoding="utf-8"))
    by_id = {s["id"]: s for s in data["stations"]}
    missing = [i for i in SPIKE_STATION_IDS if i not in by_id]
    if missing:
        sys.exit(f"Station ids not in {STATIONS_JSON.name}: {missing}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    fetched = skipped = 0
    for sid in SPIKE_STATION_IDS:
        station = by_id[sid]
        row = {"name": station["name"]}
        for lang, field in LANGS:
            fname = f"{sid}_{lang}.wav"
            row[lang] = fname
            out = OUT_DIR / fname
            if out.exists():
                skipped += 1
                continue
            wav = synthesize(key, station[field], lang, args.model, args.speaker)
            out.write_bytes(wav)
            fetched += 1
            print(f"{fname}  {len(wav) // 1024} KB  ({station[field]})")
            time.sleep(0.3)  # stay polite to the API
        rows.append(row)
    page = write_listen_page(rows, args.model, args.speaker)
    print(f"\n{fetched} fetched, {skipped} already present.")
    print(f"Listen: {page}")


if __name__ == "__main__":
    main()
