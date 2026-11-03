"""Impulse response of a car's exhaust from its real layout (pillar 2).

One-dimensional plane-wave acoustics with transfer matrices: the exhaust is a
chain of pipe sections (the pipe itself, catalyst and silencer chambers) ending
in an open pipe that radiates. The result is the tailpipe volume velocity per
unit volume velocity leaving the engine, as an impulse response the
synthesizer convolves with the physical exhaust signal (which already carries
the radiation d/dt). Same rules for every car.

    python3 -I pipeline/exhaust_acoustics.py "1987 Scania 113H"   # prints the response
"""

import math
import sys

import numpy as np

SAMPLE_RATE_HZ = 44100
IMPULSE_RESPONSE_SAMPLES = 4096                 # 93 ms; the convolution is direct-form
EXHAUST_GAS_SPEED_OF_SOUND = 450.0              # m/s, mean of ~700 K at the engine and cooler at the tail
WALL_LOSS_PER_SQRT_HZ = 3.0e-5                  # Np/m * m / sqrt(Hz): viscous and thermal pipe losses
# Packed (fibre/perforated) silencers: Np/m per kHz, rising to 2 kHz. Fit so
# packed boxes take ~15-25 dB off the 1-8 kHz band (2026-11-03: unpacked
# chambers left the Scania's 600-800 Hz pipe resonances 25 dB over its firing
# rumble; in game a raspy buzz).
ABSORPTIVE_LOSS_PER_KHZ = 0.6
ABSORPTIVE_LOSS_SATURATES_AT_HZ = 2000.0

# Silencer types from real_cars.json -> chamber diameter and length in pipe
# diameters, and whether it is packed with absorbing material (road-vehicle
# boxes are; a resonator is a plain chamber).
SILENCER_GEOMETRY = {
    "single-box": (3.0, 7.0, True),
    "center-box": (3.0, 6.0, True),
    "rear-box": (3.0, 7.0, True),
    "transverse-box": (3.5, 5.0, True),
    "resonator": (2.0, 4.0, False),
    "glasspack": (1.6, 6.0, True),
    "turbo-muffler": (3.0, 7.0, True),
    "stack-muffler": (2.4, 7.0, True),
    "absorptive": (2.0, 6.0, True),
    "expansion-box": (3.0, 5.0, True),
    "can-muffler": (2.5, 5.0, True),
}
CATALYST_GEOMETRY = (2.2, 3.0, True)
CATALYST_POSITION_FRACTION = 0.15               # of the exhaust length, from the engine
TAILPIPE_LENGTH_IN_PIPE_DIAMETERS = 6.0         # after the last silencer


def section_matrix(length_m, diameter_m, frequencies_hz, absorptive=False):
    """Transfer matrix [[A, B], [C, D]] of a uniform lossy pipe section."""
    area = math.pi * diameter_m ** 2 / 4.0
    characteristic_impedance = 1.0 / area      # rho*c cancels in the response
    attenuation = WALL_LOSS_PER_SQRT_HZ * np.sqrt(frequencies_hz) / (diameter_m / 2.0)
    if absorptive:
        attenuation = attenuation + ABSORPTIVE_LOSS_PER_KHZ * np.minimum(
            frequencies_hz, ABSORPTIVE_LOSS_SATURATES_AT_HZ) / 1000.0
    wavenumber = 2 * np.pi * frequencies_hz / EXHAUST_GAS_SPEED_OF_SOUND - 1j * attenuation
    kl = wavenumber * length_m
    return (np.cos(kl), 1j * characteristic_impedance * np.sin(kl),
            1j * np.sin(kl) / characteristic_impedance, np.cos(kl))


def multiply(first, second):
    a1, b1, c1, d1 = first
    a2, b2, c2, d2 = second
    return (a1 * a2 + b1 * c2, a1 * b2 + b1 * d2, c1 * a2 + d1 * c2, c1 * b2 + d1 * d2)


def exhaust_sections(exhaust, exhaust_length_m):
    """(length, diameter, absorptive) from the engine to the tailpipe."""
    pipe = exhaust["pipe_mm"] / 1000.0
    chambers = []
    if exhaust.get("catalyst"):
        chambers.append((CATALYST_POSITION_FRACTION, CATALYST_GEOMETRY))
    silencers = exhaust.get("silencers") or []
    for index, silencer in enumerate(silencers):
        geometry = SILENCER_GEOMETRY.get(silencer)
        if geometry is None:
            raise ValueError(f"unknown silencer type {silencer!r}")
        # Spread front to back; the last sits a tailpipe length from the outlet.
        position = 0.45 + 0.5 * (index + 1) / len(silencers)
        chambers.append((position, geometry))
    tailpipe = TAILPIPE_LENGTH_IN_PIPE_DIAMETERS * pipe
    sections, cursor = [], 0.0
    for position, (diameter_ratio, length_ratio, absorptive) in sorted(chambers):
        chamber_length = length_ratio * pipe
        start = min(max(position * exhaust_length_m - chamber_length / 2.0, cursor),
                    exhaust_length_m - tailpipe - chamber_length)
        if start > cursor:
            sections.append((start - cursor, pipe, False))
        sections.append((chamber_length, diameter_ratio * pipe, absorptive))
        cursor = start + chamber_length
    sections.append((max(exhaust_length_m - cursor, tailpipe), pipe, False))
    return sections


def exhaust_impulse_response(exhaust, exhaust_length_m):
    frequencies = np.fft.rfftfreq(IMPULSE_RESPONSE_SAMPLES * 4, 1.0 / SAMPLE_RATE_HZ)
    frequencies[0] = 1e-3                     # the response is smooth at DC
    total = (np.ones_like(frequencies), np.zeros_like(frequencies),
             np.zeros_like(frequencies), np.ones_like(frequencies))
    for length, diameter, absorptive in exhaust_sections(exhaust, exhaust_length_m):
        total = multiply(total, section_matrix(length, diameter, frequencies, absorptive))
    outlet = exhaust["pipe_mm"] / 2000.0
    outlet_impedance = (1.0 / (math.pi * outlet ** 2))
    wavenumber = 2 * np.pi * frequencies / EXHAUST_GAS_SPEED_OF_SOUND
    # Unflanged open end: radiation resistance and end correction.
    radiation = outlet_impedance * (0.25 * (wavenumber * outlet) ** 2 + 1j * 0.61 * wavenumber * outlet)
    a, b, c, d = total
    tailpipe_per_engine_volume_velocity = 1.0 / (c * radiation + d)
    response = np.fft.irfft(tailpipe_per_engine_volume_velocity)[:IMPULSE_RESPONSE_SAMPLES]
    fade = np.ones(IMPULSE_RESPONSE_SAMPLES)
    fade[-512:] = np.hanning(1024)[512:]
    return response * fade


def write_wav_int16(path, response):
    """Peak-normalised 16-bit WAV; returns the volume that restores the scale."""
    import wave
    peak = float(np.max(np.abs(response)))
    samples = np.round(response / peak * 32767).astype("<i2")
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE_HZ)
        wav.writeframes(samples.tobytes())
    return peak


if __name__ == "__main__":
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    import generate_engine_scripts as generator
    _, cars = generator.load_specs()
    car = next(c for c in cars if c["real_car"] == sys.argv[1])
    length = generator.exhaust_length_m(car)
    print(exhaust_sections(car["exhaust"], length))
    h = exhaust_impulse_response(car["exhaust"], length)
    spectrum = np.abs(np.fft.rfft(h, 16384))
    bins = np.fft.rfftfreq(16384, 1 / SAMPLE_RATE_HZ)
    for low, high in [(20, 60), (60, 150), (150, 300), (300, 600), (600, 1200), (1200, 3000), (3000, 8000)]:
        mask = (bins >= low) & (bins < high)
        print(low, high, round(20 * np.log10(spectrum[mask].mean() + 1e-12), 1))
