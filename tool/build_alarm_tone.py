"""Generate assets/audio/wake_alarm.wav, the wake escalation's looping alarm tone.

A rising three-note chime (a major arpeggio) every 1.25 seconds, over a 5
second loop, each note struck softly like a bell and then sustained.

WHY IT CHANGED, 13 Oct 2026. The first tone was a beep pair at 880 and 1245 Hz.
A tester riding on the phone SPEAKER (Vinith, Kalyan to Ambernath, 4 Sep) heard
it "up to a limit" and lost it in station noise. Phone speakers are weak below
about 1 kHz, and train noise is strongest exactly there, so the old tone sat in
the band easiest to drown. The notes now sit at 1.8 to 2.6 kHz with overtones to
about 9 kHz: where a phone speaker is loudest, where hearing is most sensitive,
and where rumble is weakest.

IT MUST NEVER SOUND LIKE DANGER. This plays in packed coaches, and a sound
people read as a threat can start a panic, which in a crowd is a hazard in
itself. So, by rule, the owner's:

- no siren: no fast high-low alternation like an ambulance or police car;
- no acceleration: beeps that speed up read as a film bomb timer, so the TEMPO
  IS FIXED and only the volume climbs, per rung, in code;
- no buzzer: no square wave, no harsh fire-alarm rasp;
- musical: a major chord rising, struck like a bell, so it reads as what it
  is, somebody's phone alarm clock.

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

SAMPLE_RATE = 22050  # Nyquist 11 kHz, above the highest overtone kept
LOOP_SECONDS = 5.0
# One chime every 1.25 s, NEVER faster (see above). The owner picked this on
# the 3T speaker on 13 Oct over a once-a-second version: calmer, as loud.
PHRASE_EVERY_SECONDS = 1.25

# A6, C#7, E7: an A major arpeggio, rising. Rising reads as "get up", a major
# chord reads as friendly, and none of the three steps is a siren interval.
NOTES_HZ = (1760.0, 2217.5, 2637.0)
NOTE_SECONDS = 0.32
NOTE_GAP_SECONDS = 0.06  # notes never overlap: overlap stacks peaks, and a
# stacked peak is headroom spent on nothing the ear hears as louder
ATTACK_SECONDS = 0.015  # a soft strike, not a click: part of "calm"
RELEASE_SECONDS = 0.04
DECAY_PER_SECOND = 1.2  # a slow ring-down: struck, but sustained

# Overtone weights: the strike's brightness. Integer partials keep it musical,
# not clangy, and put energy at 3.5 to 9 kHz where a speaker is strong.
PARTIALS = ((1, 1.0), (2, 0.55), (3, 0.28), (4, 0.14))
MAX_PARTIAL_HZ = 9000.0

# Gentle saturation, which lowers the peak-to-average ratio so the same peak
# carries more sound. 1.5 is chosen BELOW the louder 2.5: by 2.5 the edge starts
# to read as a buzzer, which the rules above forbid.
DRIVE = 1.5

PEAK = 0.97  # of full scale

# MEASURED 13 Oct 2026 against the 880/1245 Hz beep it replaced, through a
# modelled phone speaker (4th order roll-off below 800 Hz) and A-weighting:
# +7.1 dB. A model, not a phone: the desk bench in noise is the real test.


def note(freq_hz: float) -> list[float]:
    n = int(NOTE_SECONDS * SAMPLE_RATE)
    samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        value = 0.0
        for k, weight in PARTIALS:
            if freq_hz * k > MAX_PARTIAL_HZ:
                break
            # Higher partials die faster, which is what makes a strike sound
            # like a bell rather than an organ.
            value += weight * math.sin(2 * math.pi * freq_hz * k * t) * math.exp(
                -DECAY_PER_SECOND * (k - 1) * 0.5 * t
            )
        envelope = math.exp(-DECAY_PER_SECOND * t)
        envelope *= min(1.0, t / ATTACK_SECONDS)
        envelope *= min(1.0, (NOTE_SECONDS - t) / RELEASE_SECONDS)
        samples.append(value * envelope)
    return samples


def build_loop() -> list[float]:
    total = int(LOOP_SECONDS * SAMPLE_RATE)
    samples = [0.0] * total
    notes = [note(f) for f in NOTES_HZ]
    phrases = int(LOOP_SECONDS / PHRASE_EVERY_SECONDS)
    for p in range(phrases):
        for j, struck in enumerate(notes):
            offset = j * (NOTE_SECONDS + NOTE_GAP_SECONDS)
            start = int((p * PHRASE_EVERY_SECONDS + offset) * SAMPLE_RATE)
            for i, v in enumerate(struck):
                samples[start + i] += v
    peak = max(abs(v) for v in samples)
    norm = math.tanh(DRIVE)
    return [math.tanh(DRIVE * v / peak) / norm for v in samples]


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
