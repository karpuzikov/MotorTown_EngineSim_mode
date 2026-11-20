"""Write the two brighter versions of Engine Simulator's road muffler for settings.ini "muffler".

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
VARIANT_GAINS_DB = {"smooth_39_treble_plus_8db.wav": 8.0, "smooth_39_treble_plus_14db.wav": 14.0}
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


def main():
    source, target_folder = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    sample_rate, recording = wavfile.read(source)
    recording = recording.astype(np.float64)
    if recording.ndim > 1:
        recording = recording[:, 0]  # Engine Simulator reads the first channel
    target_folder.mkdir(parents=True, exist_ok=True)
    for name, gain_db in VARIANT_GAINS_DB.items():
        brighter = lfilter(*high_shelf_coefficients(SHELF_CORNER_HZ, gain_db, sample_rate), recording)
        # The boost raises the peak; scale into int16. Engine Simulator's leveler restores the loudness.
        brighter *= min(1.0, INT16_HEADROOM / np.abs(brighter).max())
        wavfile.write(target_folder / name, sample_rate, brighter.astype(np.int16))
        print(f"wrote {target_folder / name}")


if __name__ == "__main__":
    main()
