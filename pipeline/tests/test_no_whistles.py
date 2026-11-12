"""No exhaust response the mod ships may whistle (owner, 2026-11-11: "remove it from any and all engines! prevent it from
appearing ever again").

Same measurement as EngineVoice's tools/engine_voice_analysis/remove_whistles.py (which also cleans the files): the
response as Engine Simulator loads it (up to the last sample above 100, at most 10000), power spectrum smoothed to 10.8 Hz,
each frequency between 1 and 19 kHz compared with the median of the 400 Hz around it. Engine Simulator's own library comes
from the pinned fork, which carries the cleaned files.
"""
import sys
import unittest
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import medfilt

PROFILES = Path(__file__).resolve().parents[2] / "native" / "profiles"
WHISTLE_LIMIT_DB = 3.0
SPECTRUM_RESOLUTION_HZ = 10.8
NEIGHBOURHOOD_HZ = 400.0


def worst_whistle(path):
    sample_rate, response = wavfile.read(path)
    response = response.astype(np.float64)
    if response.ndim > 1:
        response = response[:, 0]
    loud = np.nonzero(np.abs(response) > 100)[0]
    response = response[:min(10000, loud[-1] + 1)]
    size = 1 << int(np.ceil(np.log2(max(len(response), sample_rate / SPECTRUM_RESOLUTION_HZ))))
    frequencies = np.fft.rfftfreq(size, 1 / sample_rate)
    power = np.abs(np.fft.rfft(response, size)) ** 2
    smoothing_bins = max(1, int(round(SPECTRUM_RESOLUTION_HZ / frequencies[1])))
    power_db = 10 * np.log10(np.convolve(power, np.ones(smoothing_bins) / smoothing_bins, mode="same") + 1e-30)
    prominence_db = power_db - medfilt(power_db, int(NEIGHBOURHOOD_HZ / frequencies[1]) | 1)
    searched = (frequencies > 1000) & (frequencies < 19000)
    index = int(np.argmax(prominence_db[searched]))
    return frequencies[searched][index], prominence_db[searched][index]


class NoWhistleTest(unittest.TestCase):
    def test_every_shipped_exhaust_response_is_whistle_free(self):
        responses = sorted(PROFILES.rglob("*.wav"))
        self.assertTrue(responses)
        for response in responses:
            with self.subTest(response=response.relative_to(PROFILES)):
                frequency, prominence = worst_whistle(response)
                self.assertLessEqual(prominence, WHISTLE_LIMIT_DB, f"{prominence:.1f} dB whistle at {frequency:.0f} Hz")


if __name__ == "__main__":
    sys.exit(unittest.main())
