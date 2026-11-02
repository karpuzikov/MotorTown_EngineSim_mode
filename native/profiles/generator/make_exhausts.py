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

Damping is what makes it a muffler, not a pipe: mean-flow losses at every
area change and at the exhaust jet, rough-wall turbulence, perforated
baffles and packing. Without them (first version) every system rang for
110-150 ms like a bare pipe; recorded exhausts decay in 25-45 ms.

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
MEAN_FLOW_MACH = 0.1     # exhaust gas speed / sound speed at cruise
WALL_TURBULENCE = 3.0    # rough hot pipes with flow lose more than Kirchhoff's smooth tube

# Element kinds: pipe(length, diameter); cat(length, diameter, absorption);
# chamber(length, diameter): a chambered muffler box - inlet and outlet tubes
# extend into it (L/2, L/4: their closed annular cavities fill the pass bands
# a bare expansion chamber leaves at kL = n*pi) through perforated baffles;
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
    "truck_stack": [("pipe", 2.2, 0.127), ("absorb", 0.9, 0.127, 1.5), ("pipe", 1.8, 0.127)],
    "truck_euro": [("pipe", 2.0, 0.11), ("chamber", 0.7, 0.40), ("pipe", 0.25, 0.11)],
    "bus_rear": [("pipe", 0.7, 0.10), ("chamber", 1.0, 0.35), ("pipe", 0.25, 0.10)],
    "bus_detroit": [("pipe", 0.7, 0.10), ("chamber", 1.0, 0.35), ("pipe", 0.25, 0.10)],
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
    alpha = WALL_TURBULENCE * 3e-5 * np.sqrt(f) / (diameter / 2) + absorption * (f / 1000.0)
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


def area(diameter):
    return np.pi * diameter ** 2 / 4


def series(f, resistance):
    one, zero = np.ones_like(f, dtype=complex), np.zeros_like(f, dtype=complex)
    return np.array([[one, zero + resistance], [zero, one]])


def shunt(f, branch_impedance):
    one, zero = np.ones_like(f, dtype=complex), np.zeros_like(f, dtype=complex)
    return np.array([[one, zero], [1 / branch_impedance, one]])


def junction(f, upstream_diameter, downstream_diameter):
    """Sudden area change with mean flow: the jet separating at an expansion
    (and the vena contracta at a contraction) turns sound into vorticity -
    the main damping of a real exhaust; without it every pipe rings."""
    small, large = sorted((area(upstream_diameter), area(downstream_diameter)))
    loss = (1 - small / large) ** 2 if downstream_diameter > upstream_diameter \
        else 0.5 * (1 - small / large)
    return series(f, loss * MEAN_FLOW_MACH * DENSITY * SPEED_OF_SOUND / small)


MUFFLER_PACKING = 2.0     # Np/m at 1 kHz: light packing in OEM muffler boxes
BAFFLE_RESISTANCE = 0.3   # perforated baffle flow resistance, x rho*c/S_pipe


def chambered_muffler(f, length, diameter, pipe_diameter):
    inlet_extension, outlet_extension = length / 2, length / 4
    annulus = area(diameter) - area(pipe_diameter)
    impedance = DENSITY * SPEED_OF_SOUND / annulus

    def closed_cavity(depth):  # annular quarter-wave side branch
        k = wave_number(f, diameter, MUFFLER_PACKING)
        return -1j * impedance / np.tan(k * depth)
    body = duct(f, length - inlet_extension - outlet_extension, diameter, MUFFLER_PACKING)
    baffle = series(f, BAFFLE_RESISTANCE * DENSITY * SPEED_OF_SOUND / area(pipe_diameter))
    return chain([baffle, shunt(f, closed_cavity(inlet_extension)), body,
                  shunt(f, closed_cavity(outlet_extension)), baffle])


def chain(matrices):
    total = matrices[0]
    for matrix in matrices[1:]:
        total = np.einsum("ijn,jkn->ikn", total, matrix)
    return total


def element(f, kind, args, pipe_diameter):
    if kind in ("pipe", "cat", "absorb"):
        return duct(f, *args)
    if kind == "chamber":
        return chambered_muffler(f, *args, pipe_diameter)
    if kind == "resonator":
        return resonator(f, *args)
    raise ValueError(kind)


def physical_response(layout):
    """Tailpipe volume velocity per unit valve flow (transfer-matrix model)."""
    f = frequencies()
    matrices = []
    pipe_diameter = layout[0][2]
    for kind, *args in layout:
        diameter = args[1] if kind != "resonator" else pipe_diameter
        if kind != "chamber" and diameter != pipe_diameter:
            matrices.append(junction(f, pipe_diameter, diameter))
        if kind == "chamber":  # flow expands into the box and contracts out
            matrices.append(junction(f, pipe_diameter, diameter))
            matrices.append(element(f, kind, args, pipe_diameter))
            matrices.append(junction(f, diameter, pipe_diameter))
            continue
        matrices.append(element(f, kind, args, pipe_diameter))
        if kind != "resonator":
            pipe_diameter = diameter
    total = chain(matrices)
    radius = pipe_diameter / 2
    ka = 2 * np.pi * f / SPEED_OF_SOUND * radius
    tail_impedance = DENSITY * SPEED_OF_SOUND / (np.pi * radius ** 2)
    # Open end: radiation plus the exhaust jet, which absorbs low-frequency
    # sound that would otherwise reflect back and make the tailpipe ring.
    radiation = tail_impedance * (0.25 * ka ** 2 + MEAN_FLOW_MACH + 1j * 0.6133 * ka)
    tail_flow = 1 / (total[1, 0] * radiation + total[1, 1])  # U_tail / U_valve
    tail_flow[0] = 0
    return tail_flow


# The physics above gives each system its resonances, damping and delays,
# but leaves out radiation, flow noise, shell and body sound, the ground and
# the listener. Those set the broad tone, taken from a recording - Engine
# Simulator's default exhaust response (sound-library/smooth/smooth_39.wav),
# octave levels in dB re 1 kHz below - tilted per vehicle class: big diesels
# deeper, small engines thinner. Each system is corrected to its class
# curve octave by octave; its physics stays within the octaves. (Before:
# the raw physics made the Dory a lawn mower and buses thin.)
OCTAVE_CENTRES_HZ = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
RECORDED_EXHAUST_OCTAVES_DB = [-1.0, -2.9, 1.4, 4.5, 8.7, 0.0, -6.5, -17.7, -28.6, -40.5]
CLASS_TILT_DB = {
    "big_diesel": [4, 6, 6, 3, 0, 0, -2, -4, -6, -6],
    "car": [0] * 10,
    "vintage": [0, 1, 1, 0, 0, 0, 0, 0, -1, -2],  # flathead/air-cooled burble, no catalyst
    # Matched to a real 1948 Ford F-1 flathead V8 recording (2026-11-02)
    # with the true flathead engine: its slow-breathing side valves are dark,
    # the recording is not (2-8 kHz only half matched: the cab adds road and
    # wind noise).
    "flathead": [-16, 10, 1, 5, 7, 22, 13, 17, 20, 17],
    # A real 1989 MCI MC-9's Detroit 6V92TA idling (cold start recording,
    # 2026-11-02): the firing thump carries ~60-80% of the sound, clatter
    # rides on top. The curve keeps the thump at -2..-4 dB of the total at
    # every RPM (idle, cruise, full throttle); fitted to idle alone, the
    # thump sank to -9 dB when driving: a "farting buzz" in game.
    # shortcut: idle runs ~5 dB less clatter and +8 dB at 125 Hz vs the
    # recording; no real driving recording to fit the rest.
    "detroit": [26, 42, 28, 26, 36, 41, 43, 37, 41, 56],
    "small": [-3, -3, -1, 0, 0, 0, 2, 2, 1, 0],
    "sport": [-2, -2, 0, 0, 0, 0, 2, 3, 2, 0],
    "two_stroke": [-6, -6, -3, 0, 0, 0, 3, 4, 3, 0],
}
PROFILE_CLASS = {
    "vintage_single": "flathead", "classic_v8": "car", "muscle_glasspack": "sport",
    "car_modern": "car", "luxury_quiet": "car", "sports_modern": "sport",
    "turbo_sport": "sport", "supercar": "sport", "economy_small": "small",
    "soviet_two_box": "small", "kei_small": "small", "aircooled_box": "vintage",
    "pickup_van": "car", "offroad_vintage": "vintage", "truck_medium": "big_diesel",
    "military_stack": "big_diesel", "truck_stack": "big_diesel", "truck_euro": "big_diesel",
    "bus_rear": "big_diesel", "bus_detroit": "detroit", "motorcycle_twin": "sport", "sportbike": "sport",
    "scooter_2t": "two_stroke", "kart": "two_stroke",
}


# Full-throttle pass-by loudness at 7.5 m, dB(A), of the vehicles with each
# system (typical measured values: modern car ~74, semi ~88, superbike and
# supercar ~90): the native side scales Engine Simulator to it by RPM and load.
FULL_THROTTLE_LOUDNESS_DBA = {
    "vintage_single": 78, "classic_v8": 82, "muscle_glasspack": 88, "car_modern": 74,
    "luxury_quiet": 71, "sports_modern": 79, "turbo_sport": 82, "supercar": 90,
    "economy_small": 75, "soviet_two_box": 78, "kei_small": 76, "aircooled_box": 80,
    "pickup_van": 77, "offroad_vintage": 80, "truck_medium": 84, "military_stack": 88,
    "truck_stack": 88, "truck_euro": 84, "bus_rear": 82, "motorcycle_twin": 86,
    # shortcut: the native loudness model levels RMS; this curve reads 1 dB
    # quieter in dB(A) than bus_rear at the same RMS, so 82 - 1.
    "bus_detroit": 81,
    "sportbike": 88, "scooter_2t": 80, "kart": 92,
}


def octave_levels_db(response):
    f = frequencies()
    power = np.abs(response) ** 2
    levels = [10 * np.log10(power[(f >= c / np.sqrt(2)) & (f < c * np.sqrt(2))].mean() + 1e-30)
              for c in OCTAVE_CENTRES_HZ]
    return np.array(levels) - levels[OCTAVE_CENTRES_HZ.index(1000)]


def minimum_phase(magnitude):
    """Causal filter with this rfft magnitude (cepstral method)."""
    log_magnitude = np.log(np.maximum(magnitude, 1e-8))
    cepstrum = np.fft.irfft(log_magnitude, N)
    fold = np.zeros(N)
    fold[0], fold[1:N // 2], fold[N // 2] = 1, 2, 1
    return np.exp(np.fft.rfft(cepstrum * fold))


def frequency_response(profile):
    physical = physical_response(PROFILES[profile])
    target = np.array(RECORDED_EXHAUST_OCTAVES_DB) + CLASS_TILT_DB[PROFILE_CLASS[profile]]
    correction_db = target - octave_levels_db(physical)
    gains_db = np.interp(np.log(frequencies()), np.log(OCTAVE_CENTRES_HZ), correction_db)
    response = physical * minimum_phase(10 ** (gains_db / 20))
    response[0] = 0
    return response


def impulse_response(profile):
    response = np.fft.irfft(frequency_response(profile), N)
    length = int(IMPULSE_SECONDS * FS)
    response = response[:length].copy()
    fade = int(0.3 * length)
    response[-fade:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, fade)))
    return response / np.max(np.abs(response)) * 0.95


def write(profile):
    samples = np.round(impulse_response(profile) * 32767).astype("<i2")
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
