"""Write the two brighter versions of an exhaust response for settings.ini "muffler": Engine Simulator's road muffler, and
the cars' own silencers (package_mod_profiles.py writes theirs with write_variants).

Engine Simulator's road-vehicle exhaust response (ir_lib.default_0 = sound-library/smooth/smooth_39.wav) is a recording of a
real muffler. It removes most sound above about 2.5 kHz (4 kHz octave -26 dB, 8 kHz -37 dB under its loudest octave), which
the owner heard as "listening over the phone". The engine and everything below 2 kHz stay as they are; only the muffler's treble
cut is weakened by a high shelf at 2.5 kHz, baked into the file (no runtime cost):

    standard   smooth_39.wav                     Engine Simulator's own
    brighter   smooth_39_treble_plus_8db.wav     +8 dB above 2.5 kHz
    brightest  smooth_39_treble_plus_14db.wav    +14 dB above 2.5 kHz

All three picked as decent by ear on the Dory's flathead V8 (2026-11-11). Engine Simulator's leveler keeps the loudness.

    python3 pipeline/make_muffler_treble_variants.py <engine-sim>/es/sound-library/smooth/smooth_39.wav native/profiles/sound-library/smooth
"""

import pathlib
import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter

SHELF_CORNER_HZ = 2500.0
SHELF_SLOPE = 0.7
VARIANT_GAINS_DB = {"_treble_plus_8db": 8.0, "_treble_plus_14db": 14.0}
INT16_HEADROOM = 32000.0


def high_shelf_coefficients(corner_hz, gain_db, sample_rate):
    """RBJ audio-EQ-cookbook high shelf (minimum phase, so the muffler's timing stays as recorded)."""
    amplitude = 10 ** (gain_db / 40)
    omega = 2 * np.pi * corner_hz / sample_rate
    alpha = np.sin(omega) / 2 * np.sqrt((amplitude + 1 / amplitude) * (1 / SHELF_SLOPE - 1) + 2)
    cosine = np.cos(omega)
    root = 2 * np.sqrt(amplitude) * alpha
    numerator = [amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + root),
                 -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
                 amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - root)]
    denominator = [(amplitude + 1) - (amplitude - 1) * cosine + root,
                   2 * ((amplitude - 1) - (amplitude + 1) * cosine),
                   (amplitude + 1) - (amplitude - 1) * cosine - root]
    return np.array(numerator) / denominator[0], np.array(denominator) / denominator[0]


def write_variants(source, target_folder):
    """<target_folder>/<source stem>_treble_plus_8db.wav and ..._14db.wav."""
    source, target_folder = pathlib.Path(source), pathlib.Path(target_folder)
    sample_rate, recording = wavfile.read(source)
    recording = recording.astype(np.float64)
    if recording.ndim > 1:
        recording = recording[:, 0]  # Engine Simulator reads the first channel
    target_folder.mkdir(parents=True, exist_ok=True)
    for suffix, gain_db in VARIANT_GAINS_DB.items():
        brighter = lfilter(*high_shelf_coefficients(SHELF_CORNER_HZ, gain_db, sample_rate), recording)
        # The boost raises the peak; scale into int16. The backend plays every response at the same peak gain.
        brighter *= min(1.0, INT16_HEADROOM / np.abs(brighter).max())
        target = target_folder / f"{source.stem}{suffix}.wav"
        wavfile.write(target, sample_rate, brighter.astype(np.int16))
        print(f"wrote {target}")


def main():
    write_variants(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
