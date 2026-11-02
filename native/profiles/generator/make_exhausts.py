#!/usr/bin/env python3
"""Exhaust systems of the real vehicles as impulse responses.

Engine Simulator simulates each cylinder's exhaust pulse and its travel time
down the header, then gives it the tone of an exhaust by convolving with a
recorded impulse response. Motor Town has no exhaust parts, so each vehicle
gets its real exhaust layout here instead: pipes, catalytic converter,
chambered or absorptive mufflers, resonators and the tailpipe, computed with
the acoustic transfer-matrix (four-pole) method used for muffler design:

    each element:  [p_in, U_in] = T @ [p_out, U_out]
    open tailpipe: p = Z_radiation * U  (unflanged pipe end)
    impulse response = radiated sound (j*omega * U_tail) per unit valve flow

Writes native/profiles/exhaust/<profile>.wav (44.1 kHz mono PCM16).
"""
import wave
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parents[1] / "exhaust"
FS = 44100
N = 32768
SPEED_OF_SOUND = 500.0   # m/s in exhaust gas at ~350 C
DENSITY = 0.55           # kg/m^3 at ~350 C
IMPULSE_SECONDS = 0.22   # Engine Simulator uses the first 10000 samples
LOSS_ROLL_OFF_HZ = 500.0

# Element kinds: pipe(length, diameter); cat(length, diameter, absorption);
# chamber(length, diameter): an expansion chamber / chambered muffler box;
# absorb(length, diameter, absorption): perforated straight-through pipe in
# packing (glasspack, truck drum, sports muffler); resonator(volume_l, neck
# length, neck diameter): Helmholtz side branch. Absorption in Np/m at 1 kHz.
PROFILES = {
    "vintage_single": [("pipe", 1.2, 0.045), ("chamber", 0.45, 0.12), ("pipe", 0.5, 0.045)],
    "classic_v8": [("pipe", 1.6, 0.057), ("chamber", 0.25, 0.14), ("pipe", 0.08, 0.057),
                   ("chamber", 0.2, 0.14), ("pipe", 0.45, 0.057)],
    "muscle_glasspack": [("pipe", 1.6, 0.057), ("absorb", 0.45, 0.057, 0.8), ("pipe", 0.4, 0.057)],
    "car_modern": [("pipe", 0.4, 0.05), ("cat", 0.3, 0.11, 0.5), ("pipe", 1.2, 0.055),
                   ("resonator", 3.0, 0.08, 0.04), ("chamber", 0.35, 0.16), ("pipe", 0.1, 0.055),
                   ("chamber", 0.25, 0.16), ("pipe", 0.3, 0.055)],
    "luxury_quiet": [("pipe", 0.4, 0.05), ("cat", 0.35, 0.12, 0.6), ("pipe", 1.3, 0.055),
                     ("resonator", 4.0, 0.08, 0.04), ("chamber", 0.45, 0.2), ("pipe", 0.12, 0.05),
                     ("chamber", 0.35, 0.2), ("pipe", 0.3, 0.05)],
    "sports_modern": [("pipe", 0.4, 0.06), ("cat", 0.25, 0.12, 0.4), ("pipe", 0.9, 0.065),
                      ("absorb", 0.4, 0.065, 1.0), ("pipe", 0.15, 0.07)],
    "turbo_sport": [("pipe", 0.6, 0.065), ("cat", 0.25, 0.12, 0.4), ("pipe", 1.2, 0.07),
                    ("absorb", 0.35, 0.07, 0.9), ("pipe", 0.2, 0.08)],
    "supercar": [("pipe", 0.5, 0.06), ("cat", 0.2, 0.12, 0.3), ("pipe", 0.3, 0.07),
                 ("absorb", 0.25, 0.07, 0.6), ("pipe", 0.1, 0.08)],
    "economy_small": [("pipe", 0.9, 0.038), ("chamber", 0.3, 0.10), ("pipe", 0.9, 0.038),
                      ("chamber", 0.35, 0.12), ("pipe", 0.25, 0.038)],
    "soviet_two_box": [("pipe", 1.0, 0.04), ("chamber", 0.35, 0.11), ("pipe", 1.1, 0.04),
                       ("chamber", 0.45, 0.13), ("pipe", 0.3, 0.04)],
    "kei_small": [("pipe", 0.9, 0.032), ("chamber", 0.3, 0.10), ("pipe", 0.2, 0.03)],
    "aircooled_box": [("pipe", 0.6, 0.035), ("chamber", 0.25, 0.22), ("pipe", 0.12, 0.035)],
    "pickup_van": [("pipe", 0.5, 0.057), ("cat", 0.35, 0.12, 0.5), ("pipe", 1.6, 0.057),
                   ("chamber", 0.55, 0.2), ("pipe", 0.6, 0.057)],
    "offroad_vintage": [("pipe", 1.4, 0.04), ("chamber", 0.35, 0.10), ("pipe", 0.25, 0.04)],
    "truck_medium": [("pipe", 1.4, 0.09), ("chamber", 0.6, 0.25), ("pipe", 0.4, 0.09)],
    "military_stack": [("pipe", 1.0, 0.10), ("chamber", 0.45, 0.20), ("pipe", 1.2, 0.10)],
    "truck_stack": [("pipe", 2.2, 0.127), ("absorb", 0.9, 0.127, 0.5), ("pipe", 2.3, 0.127)],
    "truck_euro": [("pipe", 2.0, 0.11), ("chamber", 0.7, 0.40), ("pipe", 0.25, 0.11)],
    "bus_rear": [("pipe", 0.7, 0.10), ("chamber", 1.0, 0.35), ("pipe", 0.25, 0.10)],
    "motorcycle_twin": [("pipe", 0.9, 0.038), ("absorb", 0.4, 0.05, 0.5), ("pipe", 0.05, 0.038)],
    "sportbike": [("pipe", 0.8, 0.04), ("cat", 0.15, 0.07, 0.3), ("absorb", 0.35, 0.06, 0.7),
                  ("pipe", 0.05, 0.045)],
    "scooter_2t": [("pipe", 0.25, 0.028), ("chamber", 0.35, 0.08), ("pipe", 0.12, 0.022),
                   ("chamber", 0.12, 0.07), ("pipe", 0.06, 0.018)],
    "kart": [("pipe", 0.3, 0.03), ("chamber", 0.3, 0.09), ("pipe", 0.1, 0.025)],
}


def frequencies():
    f = np.fft.rfftfreq(N, 1 / FS)
    f[0] = 1.0  # avoid 0/0 at DC; the DC bin is removed afterwards
    return f


def wave_number(f, diameter, absorption=0.0):
    # Viscothermal wall loss (Kirchhoff) plus absorptive packing.
    alpha = 3e-5 * np.sqrt(f) / (diameter / 2) + absorption * (f / 1000.0)
    return 2 * np.pi * f / SPEED_OF_SOUND - 1j * alpha


def duct(f, length, diameter, absorption=0.0):
    impedance = DENSITY * SPEED_OF_SOUND / (np.pi * diameter ** 2 / 4)
    kl = wave_number(f, diameter, absorption) * length
    return np.array([[np.cos(kl), 1j * impedance * np.sin(kl)],
                     [1j * np.sin(kl) / impedance, np.cos(kl)]])


def resonator(f, volume_litres, neck_length, neck_diameter):
    omega = 2 * np.pi * f
    neck_area = np.pi * neck_diameter ** 2 / 4
    effective = neck_length + 0.85 * neck_diameter  # end corrections
    branch = (1j * (omega * DENSITY * effective / neck_area -
                    DENSITY * SPEED_OF_SOUND ** 2 / (omega * volume_litres / 1000.0))
              + DENSITY * SPEED_OF_SOUND / neck_area * 0.05)
    one, zero = np.ones_like(f, dtype=complex), np.zeros_like(f, dtype=complex)
    return np.array([[one, zero], [1 / branch, one]])


def element(f, kind, *args):
    if kind == "pipe" or kind == "chamber":
        return duct(f, *args)
    if kind in ("cat", "absorb"):
        return duct(f, *args)
    if kind == "resonator":
        return resonator(f, *args)
    raise ValueError(kind)


def frequency_response(layout):
    f = frequencies()
    total = None
    for kind, *args in layout:
        matrix = element(f, kind, *args)
        total = matrix if total is None else np.einsum("ijn,jkn->ikn", total, matrix)
    tail_diameter = next(args[1] for kind, *args in reversed(layout) if kind != "resonator")
    radius = tail_diameter / 2
    ka = 2 * np.pi * f / SPEED_OF_SOUND * radius
    tail_impedance = DENSITY * SPEED_OF_SOUND / (np.pi * radius ** 2)
    radiation = tail_impedance * (0.25 * ka ** 2 + 1j * 0.6133 * ka)
    tail_flow = 1 / (total[1, 0] * radiation + total[1, 1])  # U_tail / U_valve
    # Radiated sound rises 6 dB/octave from the tailpipe flow (j*omega);
    # flow and wall losses of hot, turbulent gas and the distance to the
    # listener roll it off again above ~500 Hz (9 dB/octave).
    # shortcut: one roll-off for every system, calibrated so a typical car
    # system spreads its energy like Engine Simulator's recorded responses
    # (1-4 kHz 13 dB and 4-10 kHz 30 dB below 0.2-1 kHz); per-element flow
    # losses would let mufflers differ there too.
    response = 1j * f / 1000.0 * tail_flow / (1 + (f / LOSS_ROLL_OFF_HZ) ** 2) ** 0.75
    response[0] = 0
    return response


def impulse_response(layout):
    response = np.fft.irfft(frequency_response(layout), N)
    length = int(IMPULSE_SECONDS * FS)
    response = response[:length].copy()
    fade = int(0.3 * length)
    response[-fade:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, fade)))
    return response / np.max(np.abs(response)) * 0.95


def write(profile):
    samples = np.round(impulse_response(PROFILES[profile]) * 32767).astype("<i2")
    with wave.open(str(OUT / f"{profile}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(FS)
        out.writeframes(samples.tobytes())


def main():
    OUT.mkdir(exist_ok=True)
    for profile in PROFILES:
        write(profile)
    print(f"wrote {len(PROFILES)} exhaust impulse responses to {OUT}")


if __name__ == "__main__":
    main()
