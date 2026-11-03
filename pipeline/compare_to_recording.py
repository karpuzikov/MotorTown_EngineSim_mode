"""Octave-band spectrum of a simulated render against a real recording.

    python3 -I pipeline/compare_to_recording.py REAL.wav[:start:seconds] RENDER.wav [RENDER.wav ...]

Prints each render's spectral difference per octave (63 Hz-16 kHz) after
removing the overall level difference, and its RMS over the bands, best first.
Recordings: mono or stereo 16-bit WAV (convert mp3 with ffmpeg first).
"""
import sys

import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal

OCTAVE_EDGES_HZ = np.array([63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])


def octave_band_levels_db(spec):
    path, *window = spec.split(":")
    rate, samples = wavfile.read(path)
    samples = samples.astype(float)
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if window:
        start, seconds = float(window[0]), float(window[1])
        samples = samples[int(start * rate):int((start + seconds) * rate)]
    else:
        samples = samples[len(samples) // 4:]          # skip the start-up
    frequencies, power = signal.welch(samples, rate, nperseg=8192)
    return np.array([10 * np.log10(power[(frequencies >= low) & (frequencies < high)].sum() + 1e-20)
                     for low, high in zip(OCTAVE_EDGES_HZ[:-1], OCTAVE_EDGES_HZ[1:])])


def main(arguments):
    reference = octave_band_levels_db(arguments[0])
    results = []
    for render in arguments[1:]:
        difference = octave_band_levels_db(render) - reference
        difference -= difference.mean()
        results.append((float(np.sqrt(np.mean(difference ** 2))), render, difference))
    print("octaves (Hz):", " ".join(f"{edge:>5}" for edge in OCTAVE_EDGES_HZ[:-1]))
    for rms, render, difference in sorted(results, key=lambda result: result[0]):
        print(f"{rms:5.1f} dB  {render}\n             ", " ".join(f"{value:5.0f}" for value in difference))


if __name__ == "__main__":
    main(sys.argv[1:])
