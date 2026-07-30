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

  A rising perfect fourth, A5 (880 Hz) to D6 (1174.66 Hz). RISING because it
  has to read as "still here" and not as an error; every descending two-note
  figure in the world means something went wrong. A fourth rather than a fifth
  or an octave because it is the least triumphant of the consonant leaps, and
  this sound arrives every few minutes for ninety minutes.

  Soft attack (12 ms), so it never reads as a click or a notification snap.

  ~500 ms total with a clean exponential tail to true silence. The design's
  range is 400 to 600 ms. Nothing overlaps the end: a tail cut short is the
  thing that makes a chime sound cheap.

  Deliberately NOT the wake alarm's character. That sound is meant to pierce
  and be obeyed; this one is meant to be noticed and forgotten. If they are
  ever confusable in a pocket, this file is wrong.
"""

import math
import os
import struct
import wave

SAMPLE_RATE = 44100
BIT_DEPTH = 16

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "audio", "pulse_chime.wav",
)

# (start seconds, frequency Hz, peak amplitude)
NOTES = [
    (0.000, 880.00, 0.42),   # A5
    (0.130, 1174.66, 0.38),  # D6, a rising fourth
]

NOTE_DECAY = 0.34   # seconds to fall to ~1/e
TOTAL = 0.52        # seconds of file
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

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with wave.open(OUT, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(BIT_DEPTH // 8)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(bytes(frames))

    print(f"wrote {OUT}")
    print(f"  {TOTAL * 1000:.0f} ms, {SAMPLE_RATE} Hz mono, peak {peak_seen:.2f}")
    if peak_seen > 0.99:
        print("  WARNING: clipping. Lower the note amplitudes.")


if __name__ == "__main__":
    main()
