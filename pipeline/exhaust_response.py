"""The exhaust's sound path, from the real car's hardware.

Engine Simulator convolves each exhaust pulse with an impulse response, the
sound of everything between the exhaust valve and the listener. Its library
road-vehicle response (default_0) is a recording of one muffler: it rings at
428 Hz, so every engine that ran through it, a kei truck and a 13-litre
diesel alike, got that same ring, and the same half-energy frequency (410-510
Hz for 17 of 19 engines measured offline, 2026-11-05). A real engine's exhaust
note is its firing orders under a smooth low-pass: the Hyundai Mighty idling
(owner's recording, 2026-11-05) has half its energy under 100 Hz, 90 % under
200 Hz and -19 dB at 500 Hz against its loudest octave.

So the response is built from the hardware instead of recorded. A silencer is
a chamber of volume V between pipes of cross-section S: a reactive low-pass,
corner (c / 2 pi) sqrt(S / (l V)). Silencers are sized by the engine
(V ~ displacement) and pipes by the pipe, l ~ diameter, so a stage's corner
scales with sqrt(pipe diameter / displacement): the smaller the engine for its
pipe, the higher the corner. Silencers in series are stages in series, each
with its share of the volume: n silencers, n stages, each sqrt(n) higher.

The exhaust has one more pole above the chamber corners, K / corner. Above its
corner the exhaust then falls 12 dB per octave to the same high-frequency
asymptote for every corner, (1 kHz / f)^2 of its pass band: the tail pipe and
the packing, not the chambers, set the gain up there, and there is one tail
pipe however many silencers. A single pole (6 dB per octave) was tried first
and left the raw pulses of small engines at the top of the spectrum: a kei
truck idling had its 4 kHz octave level with its 125 Hz one, 11 dB hotter than
through the library response, a hiss. A second pole in every silencer, on the
other hand, left two-silencer cars 50 dB down at 4 kHz, with no air in them.

Two constants are fitted, both on one recording (the Mighty) and the Scania
DC13 truck engine (12.74 litres, 127 mm, one silencer) that idles like it: the
450 Hz corner (the 63-500 Hz octaves of the Mighty within 1 dB) and K (the
1-4 kHz octaves within 3 dB, where a corner alone left them 5 dB high or 12 dB
low). The scaling with hardware is the physics above and has no measurement
behind it. The catalyst, the outlets and the tail pipe's length are not
modelled in the response (the flow model has them).
"""

import math
import struct
from pathlib import Path

SAMPLE_RATE = 44100

# The measured anchor: one silencer, 127 mm pipe, 12.74 litres (the Scania
# DC13 truck); a 450 Hz stage matched the Mighty's idle spectrum (octaves
# 63 / 125 / 250 / 500 Hz: 0 / 0 / -7 / -17 dB; the Mighty: 0 / -3 / -7 / -18).
ANCHOR_STAGE_CORNER_HZ = 450.0
ANCHOR_PIPE_MM_PER_LITRE = 127.0 / 12.74

# The exhaust's high pole sits at K / corner (never under the corner), which
# gives every exhaust the same high-frequency asymptote, (1 kHz / f)^2. At the
# anchor it is 2222 Hz and the 1 / 2 / 4 / 8 kHz octaves are -23 / -26 / -27 /
# -36 dB (the Mighty: -22 / -24 / -27 / -30).
HIGH_ASYMPTOTE_HZ2 = 1.0e6

# Corners sit on a quarter-octave grid through the anchor, which keeps the
# file count small. Only the anchor is measured, so the scaling may carry a
# corner no further than an octave above it (a 100 cc kart on a 25 mm can would
# otherwise get an open pipe's 1.5 kHz) or half an octave below.
CORNER_STEPS_PER_OCTAVE = 4
CORNER_STEP_RANGE = (-2, 4)  # 318 Hz ... 900 Hz

# Engine Simulator scales a response by volume * sample / 32767; the mod plays
# a rule's own response at volume 0.02 (engine_sim_backend.cpp). This gain at
# 100 Hz puts the response where its previous road-vehicle response (default_0,
# volume 0.001, measured at 100 Hz over its first 10000 samples) was, so the
# leveler and the loudness laws keep their calibration.
GAIN_AT_100_HZ = 0.0706
BACKEND_VOLUME = 0.02
FULL_SCALE = 32767

# The pinned synthesizer drops every sample at or under 100 (of 32767) after
# the last one above it; keep the response's tail to that.
SYNTHESIZER_TRIM_THRESHOLD = 100


def stage_corner_step(displacement_litres, pipe_mm, silencers):
    """Grid step of each low-pass stage's corner, from the real hardware."""
    if not (displacement_litres > 0 and pipe_mm > 0 and silencers >= 1):
        raise ValueError(f"exhaust needs displacement, pipe and a silencer: "
                         f"{displacement_litres} L, {pipe_mm} mm, {silencers} silencers")
    ratio = (pipe_mm / displacement_litres) / ANCHOR_PIPE_MM_PER_LITRE
    octaves = 0.5 * math.log2(silencers * ratio)  # corner ~ sqrt(n * pipe / displacement)
    low, high = CORNER_STEP_RANGE
    return min(high, max(low, round(CORNER_STEPS_PER_OCTAVE * octaves)))


def step_corner_hz(step):
    return round(ANCHOR_STAGE_CORNER_HZ * 2.0 ** (step / CORNER_STEPS_PER_OCTAVE))


def response_name(corner_hz, stages):
    return f"exhaust/lp{stages}_{corner_hz}.wav"


def _stage_impulse(corner_hz, length):
    """One bilinear one-pole low-pass (a zero at Nyquist: no aliasing edge)."""
    k = math.tan(math.pi * corner_hz / SAMPLE_RATE)
    gain = k / (1.0 + k)
    pole = (1.0 - k) / (1.0 + k)
    # y[n] = gain (x[n] + x[n-1]) + pole y[n-1], for the impulse x = 1, 0, 0, ...
    impulse = []
    previous = 0.0
    for n in range(length):
        x = 1.0 if n <= 1 else 0.0  # x[n] + x[n-1] for the impulse
        previous = gain * x + pole * previous
        impulse.append(previous)
    return impulse


def _convolve(a, b, length):
    out = [0.0] * length
    for i, x in enumerate(a):
        if x == 0.0:
            continue
        for j, y in enumerate(b):
            if i + j >= length:
                break
            out[i + j] += x * y
    return out


def _magnitude(impulse, hz):
    re = sum(x * math.cos(2 * math.pi * hz * n / SAMPLE_RATE) for n, x in enumerate(impulse))
    im = sum(x * math.sin(2 * math.pi * hz * n / SAMPLE_RATE) for n, x in enumerate(impulse))
    return math.hypot(re, im)


def impulse_response(corner_hz, stages):
    """The response as int16 samples: `stages` silencers in series and the
    exhaust's high pole, scaled so that, played at BACKEND_VOLUME, it has
    GAIN_AT_100_HZ at 100 Hz."""
    length = 4096
    response = _stage_impulse(corner_hz, length)
    single = response
    for _ in range(stages - 1):
        response = _convolve(response, single, length)
    high_hz = max(HIGH_ASYMPTOTE_HZ2 / corner_hz, corner_hz)
    response = _convolve(response, _stage_impulse(high_hz, length), length)
    scale = GAIN_AT_100_HZ * FULL_SCALE / BACKEND_VOLUME / _magnitude(response, 100.0)
    samples = [round(x * scale) for x in response]
    last = max((n for n, s in enumerate(samples) if abs(s) > SYNTHESIZER_TRIM_THRESHOLD), default=-1)
    if last < 0 or max(abs(s) for s in samples) > FULL_SCALE:
        raise ValueError(f"response lp{stages}_{corner_hz} does not fit 16 bits")
    return samples[:last + 1]


def wav_bytes(samples):
    data = struct.pack(f"<{len(samples)}h", *samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + \
        struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16) + \
        b"data" + struct.pack("<I", len(data))
    return header + data


def write_response(directory, corner_hz, stages):
    """Writes <directory>/<response_name>; returns its name."""
    name = response_name(corner_hz, stages)
    path = Path(directory) / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(wav_bytes(impulse_response(corner_hz, stages)))
    return name


def exhaust_response(displacement_litres, pipe_mm, silencers):
    """(stage corner in Hz on the grid, number of stages) of a real exhaust."""
    return step_corner_hz(stage_corner_step(displacement_litres, pipe_mm, silencers)), silencers
