#!/usr/bin/env python3
"""Generates assets/audio/pulse_chime.wav, the Pocket Pulse sound.

WHY A SCRIPT RATHER THAN A CHECKED-IN BLOB. docs/design/pocket-pulse.md calls
for a bundled asset rather than a runtime-synthesised tone, so the sound can be
replaced by a nicer one without a code change and so Guardian Plus can sell
chime VARIANTS through the same path. A generator gives both, plus the ability
to re-cut the sound after the bench says it is too quiet or too long, which no
checked-in wav does. Same posture as tool/build_stations.py and
tool/build_clip_pack.py: the asset is an output, never hand-edited.

Standard library only, deliberately. This has to run on the owner's machine
without a pip install.

    python tool/build_pulse_chime.py

THE SOUND, and every choice is arguable at the bench:

  A rising figure, A5 (880 Hz) to D6 to E6. RISING because it has to read as
  "still here" and not as an error; every descending figure in the world means
  something went wrong.

  THREE notes over ~1.25 s, chosen by ear on 30 Jul 2026. A two-note 520 ms cut
  was audible but felt like a notification blip rather than reassurance, and a
  5 s cut was rejected because at a 2 minute cadence it would duck the rider's
  music for nearly four minutes over a 90 minute ride.

  Soft attack (12 ms), so it never reads as a click or a notification snap, and
  a clean exponential tail to true silence: a tail cut short is the thing that
  makes a chime sound cheap.

  Deliberately NOT the wake alarm's character. That sound is meant to pierce
  and be obeyed; this one is meant to be noticed and forgotten. If they are
  ever confusable in a pocket, this file is wrong.
"""

import math
import os
import sys
import struct
import wave

SAMPLE_RATE = 44100
BIT_DEPTH = 16

def _out_path(variant):
    name = "pulse_chime.wav" if variant == "default" else f"pulse_chime_{variant}.wav"
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "assets", "audio", name,
    )

# Variants, so the sound can be judged by ear instead of argued about.
#
#   python tool/build_pulse_chime.py           the shipped chime
#   python tool/build_pulse_chime.py phrase    longer, three notes
#   python tool/build_pulse_chime.py long      the 5 second version
#
# A non-default variant writes pulse_chime_<name>.wav beside the real asset so
# an A/B never overwrites what is shipping.
VARIANTS = {
    # THE SHIPPED SOUND, chosen by ear on 30 Jul 2026 against two alternatives.
    # Three notes over ~1.25 s, A5 to D6 to E6. It reads as a PHRASE rather than
    # a blip, which is what the shorter 520 ms cut felt like: audible, but more
    # notification than reassurance. A 5 s version was also cut and rejected;
    # at 2 minute cadence it would have ducked the rider's music for nearly
    # four minutes across a 90 minute ride.
    "default": {
        "notes": [
            (0.000, 880.00, 0.40),
            (0.180, 1174.66, 0.38),
            (0.400, 1318.51, 0.34),
        ],
        "decay": 0.55,
        "total": 1.25,
    },
    # The original two-note cut, kept so the comparison can be repeated.
    "short": {
        "notes": [(0.000, 880.00, 0.42), (0.130, 1174.66, 0.38)],
        "decay": 0.34,
        "total": 0.52,
    },
    # Five seconds, as asked for: the same figure repeated with long tails, so
    # it fills the time without becoming a drone.
    "long": {
        "notes": [
            (0.000, 880.00, 0.34),
            (0.180, 1174.66, 0.32),
            (0.400, 1318.51, 0.30),
            (1.600, 880.00, 0.30),
            (1.780, 1174.66, 0.28),
            (2.000, 1318.51, 0.26),
            (3.200, 880.00, 0.26),
            (3.380, 1174.66, 0.24),
            (3.600, 1318.51, 0.22),
        ],
        "decay": 0.70,
        "total": 5.00,
    },
}

VARIANT = sys.argv[1] if len(sys.argv) > 1 else "default"
_spec = VARIANTS[VARIANT]

NOTES = _spec["notes"]
NOTE_DECAY = _spec["decay"]
TOTAL = _spec["total"]
ATTACK = 0.012      # seconds


def voice(t_since_start, freq, peak):
    """One struck note: fundamental plus a quiet octave for warmth."""
    if t_since_start < 0:
        return 0.0
    # Exponential decay, the shape a struck object actually makes. A linear
    # fade sounds synthetic because nothing in the physical world fades that
    # way.
    envelope = math.exp(-t_since_start / NOTE_DECAY)
    # Soft attack, so the onset is a swell rather than a click.
    if t_since_start < ATTACK:
        envelope *= t_since_start / ATTACK
    fundamental = math.sin(2 * math.pi * freq * t_since_start)
    # The octave decays faster than the fundamental, which is what makes a
    # struck sound bright at the front and mellow at the back.
    octave = math.sin(4 * math.pi * freq * t_since_start) * 0.18 * math.exp(
        -t_since_start / (NOTE_DECAY * 0.5)
    )
    return peak * envelope * (fundamental + octave)


def main():
    frame_count = int(SAMPLE_RATE * TOTAL)
    frames = bytearray()
    peak_seen = 0.0

    for i in range(frame_count):
        t = i / SAMPLE_RATE
        sample = sum(voice(t - start, freq, peak) for start, freq, peak in NOTES)

        # A final fade over the last 30 ms guarantees the file ends at true
        # zero. A wav that stops mid-waveform clicks on some Android decoders,
        # and a click at the end of a reassurance sound is the one artefact
        # that would make it read as a fault.
        remaining = TOTAL - t
        if remaining < 0.030:
            sample *= remaining / 0.030

        peak_seen = max(peak_seen, abs(sample))
        clipped = max(-1.0, min(1.0, sample))
        frames += struct.pack("<h", int(clipped * 32767))

    out = _out_path(VARIANT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with wave.open(out, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(BIT_DEPTH // 8)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(bytes(frames))

    print(f"wrote {out}")
    print(f"  {TOTAL * 1000:.0f} ms, {SAMPLE_RATE} Hz mono, peak {peak_seen:.2f}")
    if peak_seen > 0.99:
        print("  WARNING: clipping. Lower the note amplitudes.")


if __name__ == "__main__":
    main()
