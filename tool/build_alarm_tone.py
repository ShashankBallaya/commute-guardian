"""Generate assets/audio/wake_alarm.wav, the wake escalation's looping alarm tone.

A rising two-tone beep pair (low then high) once per second, over a 5 second
loop. The pair rises because a rising interval reads as "get up" where a falling
one reads as "done"; the beeps carry a second harmonic so they cut through
earphone padding and sleep better than a pure sine would.

The tone is played by audioplayers on the Android ALARM stream (its own volume,
separate from media) and the iOS playback category (silent switch cannot mute
it), with the volume ramp applied per rung in code via setVolume. This file only
defines the waveform, at full scale.

Same rule as the station JSON: this asset is GENERATED, never hand-edited.
Tweak the constants and rerun.

Run:  python tool/build_alarm_tone.py
"""

from __future__ import annotations

import math
import pathlib
import struct
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "audio" / "wake_alarm.wav"

SAMPLE_RATE = 22050  # plenty for a 2.5 kHz-band alarm, keeps the asset small
LOOP_SECONDS = 5.0
PAIR_EVERY_SECONDS = 1.0  # one rising pair per second

LOW_HZ = 880.0  # A5
HIGH_HZ = 1245.0  # roughly D#6, a rising major-ish leap
BEEP_SECONDS = 0.18
GAP_SECONDS = 0.09  # silence between the low and high beep of a pair
FADE_SECONDS = 0.012  # linear fade in/out so beep edges do not click

PEAK = 0.85  # of full scale; headroom so the harmonic sum never clips
HARMONIC_LEVEL = 0.35  # second harmonic mixed in for bite


def beep(freq_hz: float) -> list[float]:
    n = int(BEEP_SECONDS * SAMPLE_RATE)
    fade_n = int(FADE_SECONDS * SAMPLE_RATE)
    samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        value = math.sin(2 * math.pi * freq_hz * t)
        value += HARMONIC_LEVEL * math.sin(2 * math.pi * 2 * freq_hz * t)
        value /= 1 + HARMONIC_LEVEL
        if i < fade_n:
            value *= i / fade_n
        elif i >= n - fade_n:
            value *= (n - 1 - i) / fade_n
        samples.append(value)
    return samples


def build_loop() -> list[float]:
    total = int(LOOP_SECONDS * SAMPLE_RATE)
    samples = [0.0] * total
    low = beep(LOW_HZ)
    high = beep(HIGH_HZ)
    pair_starts = [
        int(k * PAIR_EVERY_SECONDS * SAMPLE_RATE)
        for k in range(int(LOOP_SECONDS / PAIR_EVERY_SECONDS))
    ]
    for start in pair_starts:
        for i, v in enumerate(low):
            samples[start + i] = v
        high_start = start + len(low) + int(GAP_SECONDS * SAMPLE_RATE)
        for i, v in enumerate(high):
            samples[high_start + i] = v
    return samples


def main() -> None:
    samples = build_loop()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)  # 16-bit
        f.setframerate(SAMPLE_RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s * PEAK)) * 32767))
            for s in samples
        )
        f.writeframes(frames)
    size_kb = OUT.stat().st_size / 1024
    print(f"Wrote {OUT} ({LOOP_SECONDS:.0f}s loop, {size_kb:.0f} KB)")


if __name__ == "__main__":
    main()
