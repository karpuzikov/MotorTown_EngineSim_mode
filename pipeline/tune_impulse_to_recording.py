"""Shape an exhaust impulse response so a simulated engine's spectrum follows a real recording.

    python3 -I pipeline/tune_impulse_to_recording.py REAL.wav[:start:seconds] RENDER.wav BASE_IR.wav BASE_VOLUME OUT.wav

RENDER.wav is a pipeline-generated engine of the recorded car played through
BASE_IR (the volume its script gives it: 0.01 for the new/ library responses)
at the recording's speeds (an rpm sweep over the range the recording covers).
The result is the one exhaust response for every vehicle (pillar 3). The third-octave difference
between recording and render, with the overall level removed, becomes a
minimum-phase equalizer that is convolved into BASE_IR, so the pipe's own
resonances survive and only the tonal balance moves. Written as a mono 16-bit
44.1 kHz WAV the mod loads as a vehicle exhaust (`#exhaust=` in
engine_families.tsv, see package_mod_profiles.py), which it plays at
PLAYBACK_VOLUME: the samples are scaled so the engine is as loud as it was with BASE_IR.
"""
import sys
from pathlib import Path

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_to_recording import read_samples  # noqa: E402

SAMPLE_RATE = 44100
BAND_CENTRES_HZ = np.array([25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                            1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000])
LEVEL_REFERENCE_HZ = (100, 4000)    # bands that set the overall level
MAX_CORRECTION_DB = 15.0            # a recording's room and microphone must not be copied wholesale
LOW_CUT_HZ = 25                     # nothing below is engine sound; fall 12 dB per octave under it
FILTER_LENGTH = 4096
FREQUENCY_POINTS = 1 << 14
TAIL_FADE_SAMPLES = 2000
PLAYBACK_VOLUME = 0.02              # engine_sim_backend.cpp VehicleExhaustImpulseVolume (headroom for the equalizer boost)


def band_levels_db(spec):
    rate, samples = read_samples(spec)
    if rate != SAMPLE_RATE:
        raise ValueError(f"{spec}: {rate} Hz, expected {SAMPLE_RATE}")
    frequencies, power = signal.welch(samples, rate, nperseg=1 << 15)
    half_band = 2 ** (1 / 6)
    return np.array([
        10 * np.log10(power[(frequencies >= centre / half_band) & (frequencies < centre * half_band)].sum() + 1e-20)
        for centre in BAND_CENTRES_HZ])


def correction_db(real_spec, render_spec):
    difference = band_levels_db(render_spec) - band_levels_db(real_spec)
    reference = (BAND_CENTRES_HZ >= LEVEL_REFERENCE_HZ[0]) & (BAND_CENTRES_HZ <= LEVEL_REFERENCE_HZ[1])
    difference -= np.median(difference[reference])
    correction = np.clip(-difference, -MAX_CORRECTION_DB, MAX_CORRECTION_DB)
    smoothed = np.convolve(np.pad(correction, 1, mode="edge"), np.ones(3) / 3, mode="valid")
    return smoothed


def level_change_db(render_spec, correction):
    """How much louder the equalizer makes the render, over the bands it covers."""
    power = 10 ** (band_levels_db(render_spec) / 10)
    return 10 * np.log10(np.sum(power * 10 ** (correction / 10)) / np.sum(power))


def minimum_phase_filter(correction):
    frequencies = np.fft.rfftfreq(FREQUENCY_POINTS, 1 / SAMPLE_RATE)
    gain_db = np.interp(np.log2(np.maximum(frequencies, 1)), np.log2(BAND_CENTRES_HZ), correction)
    gain_db = np.where(frequencies < LOW_CUT_HZ,
                       gain_db - 12 * np.log2(LOW_CUT_HZ / np.maximum(frequencies, 1)), gain_db)
    cepstrum = np.fft.irfft(gain_db / 20 * np.log(10), FREQUENCY_POINTS)
    folded = np.zeros(FREQUENCY_POINTS)
    folded[0] = cepstrum[0]
    folded[1:FREQUENCY_POINTS // 2] = 2 * cepstrum[1:FREQUENCY_POINTS // 2]
    folded[FREQUENCY_POINTS // 2] = cepstrum[FREQUENCY_POINTS // 2]
    response = np.fft.irfft(np.exp(np.fft.rfft(folded)), FREQUENCY_POINTS)[:FILTER_LENGTH]
    return response * np.hanning(2 * FILTER_LENGTH)[FILTER_LENGTH:]


def tuned_impulse(base, correction, base_volume):
    """base * equalizer as int16: base's energy at base_volume, tail faded, for PLAYBACK_VOLUME."""
    tuned = np.convolve(base, minimum_phase_filter(correction))
    tuned *= np.sqrt(np.sum(base ** 2) / np.sum(tuned ** 2)) * base_volume / PLAYBACK_VOLUME
    tuned[-TAIL_FADE_SAMPLES:] *= np.hanning(2 * TAIL_FADE_SAMPLES)[TAIL_FADE_SAMPLES:]
    if np.abs(tuned).max() > np.iinfo(np.int16).max:
        raise ValueError("the tuned response does not fit 16 bits at the playback volume")
    return np.round(tuned).astype(np.int16)


def main(arguments):
    if len(arguments) != 5:
        raise SystemExit(__doc__)
    real_spec, render_spec, base_path, base_volume, out_path = arguments
    rate, base = wavfile.read(base_path)
    if rate != SAMPLE_RATE or base.ndim != 1:
        raise ValueError(f"{base_path}: needs a mono {SAMPLE_RATE} Hz WAV")
    correction = correction_db(real_spec, render_spec)
    change = level_change_db(render_spec, correction)
    # The engine stays as loud as it was: undo what the equalizer does to the render's level.
    volume = float(base_volume) * 10 ** (-change / 20)
    wavfile.write(out_path, SAMPLE_RATE, tuned_impulse(base.astype(float), correction, volume))
    print("correction dB:", " ".join(f"{centre:g}:{value:.0f}" for centre, value in zip(BAND_CENTRES_HZ, correction)))
    print(f"the equalizer changes the render's level by {change:+.1f} dB; compensated")


if __name__ == "__main__":
    main(sys.argv[1:])
