import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tune_impulse_to_recording as tuner  # noqa: E402


def write_noise(path, bass_boost_db):
    """Twenty seconds of white noise, optionally with a 12 dB-per-octave-ish bass lift below 100 Hz."""
    noise = np.random.default_rng(1).standard_normal(tuner.SAMPLE_RATE * 20) * 3000
    if bass_boost_db:
        low = signal.sosfilt(signal.butter(2, 100, fs=tuner.SAMPLE_RATE, output="sos"), noise)
        noise = noise + low * (10 ** (bass_boost_db / 20) - 1)
    wavfile.write(path, tuner.SAMPLE_RATE, np.round(noise).astype(np.int16))


def gain_db(impulse, low, high):
    """Mean power gain of an impulse response over a band."""
    power = np.abs(np.fft.rfft(impulse, 1 << 16)) ** 2
    frequencies = np.fft.rfftfreq(1 << 16, 1 / tuner.SAMPLE_RATE)
    return 10 * np.log10(power[(frequencies >= low) & (frequencies < high)].mean())


class TuneImpulseToRecordingTest(unittest.TestCase):
    def test_missing_bass_is_restored_without_moving_the_midrange(self):
        with tempfile.TemporaryDirectory() as directory:
            real, render = Path(directory, "real.wav"), Path(directory, "render.wav")
            write_noise(real, bass_boost_db=12)
            write_noise(render, bass_boost_db=0)
            correction = tuner.correction_db(str(real), str(render))
            base = np.zeros(2000)
            base[0] = 20000
            tuned = tuner.tuned_impulse(base, correction, tuner.PLAYBACK_VOLUME).astype(float)
        bass_gain = gain_db(tuned, 40, 63) - gain_db(tuned, 800, 1250)
        # The bass lift is 12 dB below 100 Hz; the fit is smoothed and capped.
        self.assertGreater(bass_gain, 9)
        self.assertLess(bass_gain, 15)

    def test_correction_is_capped(self):
        with tempfile.TemporaryDirectory() as directory:
            real, render = Path(directory, "real.wav"), Path(directory, "render.wav")
            write_noise(real, bass_boost_db=40)
            write_noise(render, bass_boost_db=0)
            correction = tuner.correction_db(str(real), str(render))
        self.assertLessEqual(correction.max(), tuner.MAX_CORRECTION_DB + 1e-9)

    def test_wrong_sample_rate_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "slow.wav")
            wavfile.write(path, 22050, np.zeros(22050 * 5, dtype=np.int16))
            with self.assertRaises(ValueError):
                tuner.band_levels_db(str(path))


if __name__ == "__main__":
    unittest.main()
