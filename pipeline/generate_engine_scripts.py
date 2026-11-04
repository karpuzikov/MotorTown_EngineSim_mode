"""Generate Engine Simulator scripts (.mr) from the real-car specs.

One fixed rule set for every engine (pillar 3): real specs from
real_engines.json / real_cars.json where known, otherwise the derivation
rules below. Nothing in here is tuned per engine.

    python3 -I pipeline/generate_engine_scripts.py OUTPUT_DIR [ENGINE_ID ...]

Writes OUTPUT_DIR/<engine_id>.mr (exhaust of the first real car using it)
and OUTPUT_DIR/manifest.json describing every script, its rated figures and
which parts are not physically modelled yet.
"""

import json
import re
import os
import unicodedata
import math
import sys
from pathlib import Path

PIPELINE_DIR = Path(__file__).resolve().parent

# Air at 20 C, 1 atm; pressure drops used by Engine Simulator's flow units.
AIR_DENSITY_KG_M3 = 1.204
PRESSURE_28_INCH_H2O_PA = 6974.0      # k_28inH2O: flow bench standard
PRESSURE_1_5_INCH_HG_PA = 5080.0      # k_carb: carburettor rating standard
CUBIC_METRES_PER_SECOND_TO_CFM = 2118.88

# Derivation rules for values the spec database does not hold.
ROD_TO_STROKE_RATIO = 1.65
STROKE_TO_BORE_RATIO_WHEN_UNKNOWN = 1.15
DIESEL_COMPRESSION_WHEN_UNKNOWN = 17.0
COMPRESSION_HEIGHT_TO_BORE = 0.33
INTAKE_VALVE_TO_BORE = {2: 0.48, 4: 0.36}       # per valve, by valves per cylinder
EXHAUST_VALVE_TO_INTAKE_VALVE = 0.80
VALVE_LIFT_TO_DIAMETER = 0.28
VALVE_THROAT_AREA_FRACTION = 0.85                # valve area left beside the stem
PORT_DISCHARGE_COEFFICIENT = 0.65
# A side-valve (flathead) charge turns twice through the L-shaped chamber.
SIDE_VALVE_FLOW_FACTOR = 0.55
RUNNER_AREA_TO_VALVE_AREA = 1.3
HEAD_PORT_LENGTH_TO_BORE = 0.5
CAM_DURATION_BASE_DEG = 170.0                    # duration at 0.050" lift
CAM_DURATION_PER_PISTON_SPEED_DEG = 3.3          # per m/s mean piston speed at rated power
CAM_DURATION_LIMITS_DEG = (190.0, 260.0)
CAM_LOBE_SEPARATION_DEG = 112.0
# Two-strokes: events once per revolution, centred in crank degrees after TDC.
# Uniflow (Detroit): liner intake ports and poppet exhaust valves.
UNIFLOW_INTAKE_PORT_DURATION_DEG = 96.0          # centred on BDC
UNIFLOW_EXHAUST_VALVE_DURATION_DEG = 146.0
UNIFLOW_EXHAUST_VALVE_CENTRE_DEG = 165.0
# Crankcase-scavenged (piston-port / rotary-valve): exhaust and transfer ports.
PORTED_EXHAUST_PORT_DURATION_DEG = 170.0         # centred on BDC
PORTED_TRANSFER_PORT_DURATION_DEG = 125.0        # centred on BDC
INTAKE_PORT_AREA_TO_BORE_AREA = 0.50
EXHAUST_PORT_AREA_TO_BORE_AREA = 0.35
TWO_STROKE_MINIMUM_SCAVENGE_PRESSURE_RATIO = 1.25  # crankcase or blower must push the charge in
SPARK_ADVANCE_IDLE_DEG = 12.0
SPARK_ADVANCE_FULL_DEG = 34.0
SPARK_FULL_ADVANCE_AT_REDLINE_FRACTION = 0.55
DIESEL_INJECTION_ADVANCE_DEG = 8.0
PISTON_MASS_G_PER_BORE_CM3 = 0.45
ROD_MASS_TO_PISTON_MASS = 0.65
CRANK_MASS_KG_PER_LITRE = 4.0
FLYWHEEL_MASS_KG_AT_1_LITRE = 5.0
FLYWHEEL_MASS_EXPONENT = 0.7
FLYWHEEL_RADIUS_M_AT_1_LITRE = 0.13
FLYWHEEL_RADIUS_EXPONENT = 0.15
CRANK_FRICTION_MEAN_PRESSURE_PA = 0.4e5
THROTTLE_CFM_MARGIN = 6.0                        # fleet fit 2026-11-03 (was 1.2: choked high-rpm engines)
# Carburettors are the real restriction of carburetted engines: typical
# ratings at 1.5 inHg, scaled like every pipe flow in this model (x4).
CARBURETTOR_RATED_CFM = {"carb-1bbl": 200.0, "carb-2bbl": 350.0, "carb-4bbl": 650.0}
CARBURETTOR_FLOW_SCALE = 4.0
# Pedal released, the throttle plate's leak and idle air feed a warm engine
# at its idle speed with typical idle manifold vacuum. (A fixed 0.995 plate
# leaked 0.6-0.93 atm through the 6x throttle: idle and coasting at near
# full load.) Idle speed: the dyno's rule, a quarter of redline in 600-900 rpm.
IDLE_MANIFOLD_PRESSURE_ATM = 0.35
IDLE_RPM_PER_REDLINE_RPM = 0.25
IDLE_RPM_RANGE = (600.0, 900.0)
IDLE_LEAK_FLOW_SCALE = 1.0
PLENUM_VOLUME_TO_DISPLACEMENT = 1.0
# A diesel's fuel is injected in the cylinder; Engine Simulator premixes it in
# the intake, so a small premix volume keeps the pedal response immediate
# (the full-size plenum lagged several revolutions in game).
DIESEL_PLENUM_VOLUME_TO_DISPLACEMENT = 0.1
INTAKE_RUNNER_LENGTH_M = 0.25
CYLINDER_PITCH_TO_BORE = 1.15
PRIMARY_LENGTH_BY_MANIFOLD_M = {"cast-log": 0.20, "cast": 0.30, "turbo": 0.30, "tubular": 0.75}
PIPE_DISCHARGE_COEFFICIENT = 3.2                 # fleet fit 2026-11-03; Engine Simulator's pipe flow needs ~4x the bench figure
# A diesel is throttled like a petrol engine, never fuel-metered: Engine
# Simulator's flame goes out when the charge is leaner than about the full-load
# one, so metering fuel made every one of 28 diesels flare and stall about 1.6
# times a second (engine speed swinging 8-17% around a steady target, the
# pulsing heard in game; measured 2026-11-04). Air control holds it within 2%.
DIESEL_FULL_LOAD_LAMBDA = 1.45                   # diesels burn lean even at full load
ENGINE_SIM_INTAKE_LAMBDA = 0.8                   # fixed in Engine Simulator's Intake::process
SIMULATION_FREQUENCY_PER_REDLINE_RPM = 2.0
MINIMUM_SIMULATION_FREQUENCY_HZ = 10000

# Engine Simulator's default combustion constants (80 % burn efficiency,
# flame speed 1.5x turbulence). Its GM LS example's complete burn at 2x
# turbulence gave 18 bar BMEP without boost (2026-11-03 dyno run).
# Engine Simulator burns too slowly: best-torque spark advance hit 58 deg on
# every engine (real: 25-40). One flame-speed factor for the whole fleet,
# fitted once against rated figures; the calibration run may override it.
# Fit 2026-11-03: x3 puts best-torque advance at 22-35 deg.
FLAME_SPEED_SCALE = float(os.environ.get("MOTOR_TOWN_ENGINE_SIM_FLAME_SPEED_SCALE", "3.0"))
# With realistic burn speed the model made ~1.56x rated torque (median of
# 8 engines); this one burn efficiency stands in for the heat lost to the
# walls, which Engine Simulator does not model. Default 0.8.
# Refit on all 112 engines (2026-11-03 full run: NA petrol median +15 %).
MAX_BURNING_EFFICIENCY = float(os.environ.get("MOTOR_TOWN_ENGINE_SIM_BURN_EFFICIENCY", "0.44"))
DIESEL_BURN_SPEED_FACTOR = 3.0
FLAME_SPEED_ARGUMENT = ("turbulence_to_flame_speed_ratio: motor_town_flame_speed(), "
                        f"max_burning_efficiency: {MAX_BURNING_EFFICIENCY}")
# Boost: the pressure ratio that lifts the model's unboosted full-load mean
# effective pressure (measured, petrol median of 14 engines 2026-11-03) to
# the rated torque.
# Measured per (fuel, cycle), 2026-11-03, then refit to the full-fleet median
# error of each group at burn efficiency 0.44.
UNBOOSTED_MODEL_BMEP_PA = {
    ("petrol", 4): 9.8e5, ("multifuel", 4): 12.1e5, ("diesel", 4): 12.1e5,
    ("diesel", 2): 3.7e5, ("petrol-oil", 2): 2.6e5,
}
BOOST_PRESSURE_RATIO_LIMITS = (1.0, 3.5)
TURBO_BOOST_STARTS_AT_TORQUE_RPM_FRACTION = 0.4   # exhaust energy too low below this
TORQUE_RISE_WHEN_TORQUE_UNKNOWN = 1.3              # peak torque / torque at rated power
COMPRESSOR_EFFICIENCY = 0.70
INTERCOOLER_OUTLET_K = 320.0
AMBIENT_K = 298.15

# Best-torque (MBT) spark advance per engine, measured by the dyno's
# find-mbt search (pipeline/collect_dyno_calibration.py). Engines not in the
# file use the rule curve above.
SPARK_ADVANCE_CALIBRATION_PATH = PIPELINE_DIR / "calibration" / "spark_advance_mbt.json"
SPARK_ADVANCE_CALIBRATION = (json.loads(SPARK_ADVANCE_CALIBRATION_PATH.read_text())
                             if SPARK_ADVANCE_CALIBRATION_PATH.exists() else {})

# Calibration runs only: {"RULE_NAME": value} replaces any rule constant above.
globals().update(json.loads(os.environ.get("MOTOR_TOWN_ENGINE_SIM_RULE_OVERRIDES") or "{}"))

FUEL_SCRIPT = {
    "petrol": "fuel(name: \"Gasoline\", " + FLAME_SPEED_ARGUMENT + ")",
    "petrol-oil": "fuel(name: \"Gasoline\", " + FLAME_SPEED_ARGUMENT + ")",
    # Diesel C12H23: 167 g/mol, 17.75 mol O2 per mol fuel, 45.5 kJ/g.
    "diesel": ("fuel(name: \"Diesel\", molecular_mass: 167 * units.g, "
               "energy_density: 45.5 * units.kJ / units.g, "
               "density: 0.832 * units.kg / units.L, molecular_afr: 17.75, " + FLAME_SPEED_ARGUMENT + ")"),
}
# A multifuel engine (M35's LDT-465) is a compression-ignition diesel cycle.
FUEL_SCRIPT["multifuel"] = FUEL_SCRIPT["diesel"]


def flame_speed_node(engine):
    """Engine Simulator's default turbulence-to-flame-speed curve, scaled.

    Compression ignition: injected fuel that has mixed during the ignition
    delay burns almost at once (the diesel knock), much faster than a spark
    flame front; DIESEL_BURN_SPEED_FACTOR stands in for that rapid rise.
    """
    scale = FLAME_SPEED_SCALE * (DIESEL_BURN_SPEED_FACTOR if engine["fuel"] in ("diesel", "multifuel") else 1.0)
    samples = [(0.0, 3.0)] + [(x, 1.5 * x) for x in range(5, 50, 5)]
    lines = ["private node motor_town_flame_speed {", "    alias output __out:", "        function(5.0)"]
    lines += [f"            .add_sample({x:.1f}, {scale * y:.4f})" for x, y in samples]
    lines[-1] += ";"
    return lines + ["}", ""]


def ascii_script_text(text):
    """Piranha strings must be ASCII; "Citroën" broke the 2CV's whole script."""
    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")


def interpolate(table, x):
    if x <= table[0][0]:
        return table[0][1]
    for (x0, y0), (x1, y1) in zip(table, table[1:]):
        if x <= x1:
            return y0 + (x - x0) / (x1 - x0) * (y1 - y0)
    return table[-1][1]


def car_slug(car):
    return re.sub(r"[^a-z0-9]+", "_", ascii_script_text(car["real_car"]).lower()).strip("_")


# Engine Simulator's own exhaust response for a road vehicle with silencers.
# Every car in real_cars.json has at least one silencer. Engine Simulator's
# stock road and truck engines (chev_truck_454, gm_ls, audi i5, bmw m52b28,
# kohler) use default_0; mild_exhaust_0_reverb belongs to its sporty demo
# engines (LFA V10, F136, 2JZ). Rendered offline with the same engines
# (2026-11-04), mild_exhaust_0_reverb gave +11 dB at 125 Hz and a hollow dip at
# 250-500 Hz, a crackly top end (impulsiveness of the >3 kHz band 6-15, the
# original 454: 4) and a crest factor of 1.5-2.4 (squashed); default_0 gave the
# 454's octave profile, impulsiveness 3-5 and a natural crest factor of 2.5-3.8.
# An open pipe (minimal_muffling_01) hissed on every engine.
SILENCED_EXHAUST_IMPULSE_RESPONSE = "ir_lib.default_0"


def exhaust_impulse_response(car):
    if not car["exhaust"]["silencers"]:
        raise ValueError(f"{car['real_car']} has no silencer in its exhaust data; "
                         "wire Engine Simulator's open-pipe response (minimal_muffling_01) before generating it")
    return SILENCED_EXHAUST_IMPULSE_RESPONSE


def exhaust_runner_volume_m3(d):
    """Engine Simulator's exhaust "runner and primary": the port plus the
    primary pipe up to the collector. The port alone (~40 cc) was so small
    that flow between it and the cylinder chattered from step to step; the
    sound's derivative turned each chatter into a pop (in game: idle
    "clipping", ~1.4 pops/s on the Dory; gone with the primary's volume)."""
    return d["exhaust_runner_area"] * (d["port_length"] + d["primary_tube_length"])


def exhaust_count_for(engine, car):
    banks = bank_angles_deg(engine)
    return 2 if len(banks) == 2 and car["exhaust"]["layout"] == "dual" else 1


def load_specs():
    engines = json.loads((PIPELINE_DIR / "real_engines.json").read_text())["engines"]
    cars = json.loads((PIPELINE_DIR / "real_cars.json").read_text())["cars"]
    return {engine["id"]: engine for engine in engines}, cars


def first_car_using(engine_id, cars):
    return next(car for car in cars if engine_id in car["engines"])


def firing_angles_deg(engine):
    """Crank angle within the cycle at which each cylinder fires."""
    order = engine["firing_order"]
    cycle_deg = 360.0 * (2 if engine["cycle"] == 4 else 1)
    intervals = engine.get("fire_interval_deg") or [cycle_deg / len(order)] * len(order)
    angles, angle = {}, 0.0
    for cylinder, interval in zip(order, intervals):
        angles[cylinder] = angle
        angle += interval
    if abs(angle - cycle_deg) > 0.5:
        raise ValueError(f"{engine['id']}: fire intervals sum to {angle}, not {cycle_deg}")
    return angles


def bank_angles_deg(engine):
    # shortcut: a flat-twin (one cylinder per bank) blows up Engine Simulator's
    # solver at once; it is built as an inline twin with the same 360-degree
    # firing, which sounds alike. Upgrade when the solver issue is found.
    if engine["layout"] == "I" or (engine["layout"] == "F" and engine["cylinders"] == 2):
        return [float(engine.get("slant_deg") or 0.0)]
    if engine["layout"] == "F":
        return [-90.0, 90.0]
    if engine["layout"] in ("V", "VR"):
        half = float(engine["bank_angle"]) / 2.0
        return [-half, half]
    raise ValueError(f"{engine['id']}: unknown layout {engine['layout']}")


def journal_angle_deg(fire_deg, bank_deg, reference_bank_deg):
    # Crankshaft tdc is set to 90 deg + the reference bank, so a cylinder
    # reaches TDC at cycle angle (journal - (bank - reference bank)).
    return (fire_deg + bank_deg - reference_bank_deg) % 360.0


def cylinders_by_bank(engine, fire_deg, banks_deg):
    """Assign cylinder numbers to banks.

    Two-bank engines are numbered either alternately (1,3,5 | 2,4,6) or
    sequentially (1,2,3 | 4,5,6). On a V with shared crankpins the real
    numbering is the one where each pin pair needs the same journal angle;
    with split pins, the one whose firing order alternates banks most.
    """
    count = engine["cylinders"]
    numbers = list(range(1, count + 1))
    if len(banks_deg) == 1:
        return [numbers]
    alternate = [numbers[0::2], numbers[1::2]]
    sequential = [numbers[: count // 2], numbers[count // 2:]]
    if engine["layout"] == "F":
        return sequential
    # Cylinder 1 may sit on either bank.
    schemes = [alternate, sequential, alternate[::-1], sequential[::-1]]

    def shared_pins(banks):
        matches = 0
        for left, right in zip(*banks):
            a = journal_angle_deg(fire_deg[left], banks_deg[0], banks_deg[0])
            b = journal_angle_deg(fire_deg[right], banks_deg[1], banks_deg[0])
            matches += abs((a - b + 180.0) % 360.0 - 180.0) < 1.0
        return matches

    def bank_alternations(banks):
        bank_of = {cylinder: index for index, bank in enumerate(banks) for cylinder in bank}
        order = engine["firing_order"]
        return sum(bank_of[a] != bank_of[b] for a, b in zip(order, order[1:] + order[:1]))

    return max(schemes, key=lambda banks: (shared_pins(banks), bank_alternations(banks)))


def valve_flow_cfm(diameter_m, lift_m, valve_count, side_valve=False):
    """Flow bench figure at 28 inH2O: curtain area until the throat chokes."""
    curtain = math.pi * diameter_m * lift_m
    throat = VALVE_THROAT_AREA_FRACTION * math.pi * diameter_m ** 2 / 4.0
    velocity = math.sqrt(2.0 * PRESSURE_28_INCH_H2O_PA / AIR_DENSITY_KG_M3)
    return ((SIDE_VALVE_FLOW_FACTOR if side_valve else 1.0) * valve_count * PORT_DISCHARGE_COEFFICIENT * min(curtain, throat)
            * velocity * CUBIC_METRES_PER_SECOND_TO_CFM)


def pipe_flow_cfm(diameter_m):
    area = math.pi * diameter_m ** 2 / 4.0
    velocity = math.sqrt(2.0 * PRESSURE_1_5_INCH_HG_PA / AIR_DENSITY_KG_M3)
    return PIPE_DISCHARGE_COEFFICIENT * area * velocity * CUBIC_METRES_PER_SECOND_TO_CFM


def area_flow_cfm(area_m2):
    return pipe_flow_cfm(math.sqrt(4.0 * area_m2 / math.pi))


def intake_molecular_afr(engine):
    """The intake's molecular_afr input at full load.

    Engine Simulator's intake always mixes 0.8 x this ratio (lambda 0.8, a
    petrol full-power mixture), so a lean diesel charge divides that back out.
    """
    if engine["fuel"] in ("diesel", "multifuel"):
        return 17.75 * DIESEL_FULL_LOAD_LAMBDA / ENGINE_SIM_INTAKE_LAMBDA
    return 25.0 / 2.0


def exhaust_length_m(car):
    exhaust = car["exhaust"]
    car_length = car["length_mm"] / 1000.0
    if exhaust["tailpipe"] == "stack":
        return 2.5
    if exhaust["engine_position"] in ("rear", "mid"):
        return 1.0
    if exhaust["tailpipe"] == "side":
        return 0.5 * car_length - 0.5
    return car_length - 1.0


def exhaust_outlets(car, engine):
    exhaust = car["exhaust"]
    outlets = (exhaust.get("outlets_by_engine") or {}).get(engine["id"], exhaust["outlets"])
    return outlets


def throttle_cfm(engine, displacement_ci):
    wide_open = THROTTLE_CFM_MARGIN * displacement_ci * engine["redline_rpm"] / 3456.0
    carburettor = CARBURETTOR_RATED_CFM.get(engine.get("induction"))
    return min(wide_open, CARBURETTOR_FLOW_SCALE * carburettor) if carburettor else wide_open


def choked_to_carb_rating_flow_ratio(heat_capacity_ratio=1.4):
    """Flow through one Engine Simulator orifice when choked (idle vacuum)
    over its k_carb rating flow (1.5 inHg drop from 1 atm)."""
    g = heat_capacity_ratio
    choked = math.sqrt(g) * (2 / (g + 1)) ** ((g + 1) / (2 * (g - 1)))
    ratio = 1 - 1.5 / 29.921
    rated = math.sqrt(2 * g / (g - 1) * (1 - ratio ** ((g - 1) / g))) * ratio ** (1 / g)
    return choked / rated


def closed_throttle_plate_position(engine, displacement_ci, wide_open_cfm):
    """Engine Simulator plate position (flow scales with cos(position * pi/2))
    whose leak holds IDLE_MANIFOLD_PRESSURE_ATM at idle speed."""
    idle_rpm = min(max(IDLE_RPM_PER_REDLINE_RPM * engine["redline_rpm"], IDLE_RPM_RANGE[0]), IDLE_RPM_RANGE[1])
    idle_scfm = displacement_ci / 1728.0 * idle_rpm / (engine["cycle"] // 2) * IDLE_MANIFOLD_PRESSURE_ATM
    leak_rating_cfm = IDLE_LEAK_FLOW_SCALE * idle_scfm / choked_to_carb_rating_flow_ratio()
    return 2 / math.pi * math.acos(min(1.0, leak_rating_cfm / wide_open_cfm))


def derive(engine, car):
    """Every number the script needs, real where known, else by rule."""
    count = engine["cylinders"]
    if engine.get("bore_mm"):
        bore = engine["bore_mm"] / 1000.0
        stroke = engine["stroke_mm"] / 1000.0
    else:
        cylinder_volume = engine["displacement_cc"] * 1e-6 / count
        bore = (4.0 * cylinder_volume / (math.pi * STROKE_TO_BORE_RATIO_WHEN_UNKNOWN)) ** (1.0 / 3.0)
        stroke = STROKE_TO_BORE_RATIO_WHEN_UNKNOWN * bore
    compression = engine.get("compression") or DIESEL_COMPRESSION_WHEN_UNKNOWN
    swept_per_cylinder = math.pi / 4.0 * bore ** 2 * stroke
    displacement_litres = swept_per_cylinder * count * 1000.0
    valves = engine.get("valves_per_cyl") or 2
    intake_valves = math.ceil(valves / 2)
    exhaust_valves = valves - intake_valves
    intake_valve = (engine.get("intake_valve_mm") or 0) / 1000.0 or \
        INTAKE_VALVE_TO_BORE[2 if valves <= 2 else 4] * bore
    exhaust_valve = (engine.get("exhaust_valve_mm") or 0) / 1000.0 or \
        EXHAUST_VALVE_TO_INTAKE_VALVE * intake_valve
    lift = VALVE_LIFT_TO_DIAMETER * intake_valve
    bore_area = math.pi * bore ** 2 / 4.0

    def port(area_fraction, duration_deg, centre_deg):
        # A port as one equivalent valve whose curtain equals its full area.
        diameter = math.sqrt(4.0 * area_fraction * bore_area / (math.pi * VALVE_THROAT_AREA_FRACTION))
        return {"diameter": diameter, "count": 1, "lift": diameter / 4.0,
                "duration": duration_deg, "centre": centre_deg}
    power_rpm = engine.get("power_rpm") or 0.8 * engine["redline_rpm"]
    piston_speed = 2.0 * stroke * power_rpm / 60.0
    duration = min(max(CAM_DURATION_BASE_DEG + CAM_DURATION_PER_PISTON_SPEED_DEG * piston_speed,
                       CAM_DURATION_LIMITS_DEG[0]), CAM_DURATION_LIMITS_DEG[1])
    rod = (engine.get("rod_mm") or 0) / 1000.0 or ROD_TO_STROKE_RATIO * stroke
    piston_mass = PISTON_MASS_G_PER_BORE_CM3 * (bore * 100.0) ** 3 / 1000.0
    intake_valve_area = intake_valves * math.pi * intake_valve ** 2 / 4.0
    exhaust_valve_area = exhaust_valves * math.pi * exhaust_valve ** 2 / 4.0
    displacement_ci = displacement_litres * 61.0237
    if engine["cycle"] == 4:
        intake_event = {"diameter": intake_valve, "count": intake_valves, "lift": lift,
                        "duration": duration, "centre": 360.0 + CAM_LOBE_SEPARATION_DEG}
        exhaust_event = {"diameter": exhaust_valve, "count": exhaust_valves, "lift": lift,
                         "duration": duration, "centre": 360.0 - CAM_LOBE_SEPARATION_DEG}
        intake_event["side_valve"] = exhaust_event["side_valve"] = engine["valvetrain"] == "side-valve"
    elif engine["valvetrain"] in ("piston-port", "rotary-valve"):
        intake_event = port(INTAKE_PORT_AREA_TO_BORE_AREA, PORTED_TRANSFER_PORT_DURATION_DEG, 180.0)
        exhaust_event = port(EXHAUST_PORT_AREA_TO_BORE_AREA, PORTED_EXHAUST_PORT_DURATION_DEG, 180.0)
    else:  # uniflow: every poppet valve is an exhaust valve
        intake_event = port(INTAKE_PORT_AREA_TO_BORE_AREA, UNIFLOW_INTAKE_PORT_DURATION_DEG, 180.0)
        uniflow_valve = INTAKE_VALVE_TO_BORE[4] * bore
        exhaust_event = {"diameter": uniflow_valve, "count": valves,
                         "lift": VALVE_LIFT_TO_DIAMETER * uniflow_valve,
                         "duration": UNIFLOW_EXHAUST_VALVE_DURATION_DEG,
                         "centre": UNIFLOW_EXHAUST_VALVE_CENTRE_DEG}
    intake_valve_area = intake_event["count"] * math.pi * intake_event["diameter"] ** 2 / 4.0
    exhaust_valve_area = exhaust_event["count"] * math.pi * exhaust_event["diameter"] ** 2 / 4.0
    pipe = car["exhaust"]["pipe_mm"] / 1000.0
    return {
        "bore": bore, "stroke": stroke, "rod": rod,
        "compression_height": COMPRESSION_HEIGHT_TO_BORE * bore,
        "chamber_volume": swept_per_cylinder / (compression - 1.0),
        "displacement_litres": displacement_litres,
        "intake_event": intake_event, "exhaust_event": exhaust_event,
        "intake_runner_area": RUNNER_AREA_TO_VALVE_AREA * intake_valve_area,
        "exhaust_runner_area": RUNNER_AREA_TO_VALVE_AREA * exhaust_valve_area,
        "port_length": HEAD_PORT_LENGTH_TO_BORE * bore,
        "intake_port_peak_cfm": valve_flow_cfm(intake_event["diameter"], intake_event["lift"],
                                               intake_event["count"], intake_event.get("side_valve", False)),
        "exhaust_port_peak_cfm": valve_flow_cfm(exhaust_event["diameter"], exhaust_event["lift"],
                                                exhaust_event["count"], exhaust_event.get("side_valve", False)),
        "piston_mass": piston_mass, "rod_mass": ROD_MASS_TO_PISTON_MASS * piston_mass,
        "crank_mass": CRANK_MASS_KG_PER_LITRE * displacement_litres,
        "flywheel_mass": FLYWHEEL_MASS_KG_AT_1_LITRE * displacement_litres ** FLYWHEEL_MASS_EXPONENT,
        "flywheel_radius": FLYWHEEL_RADIUS_M_AT_1_LITRE * displacement_litres ** FLYWHEEL_RADIUS_EXPONENT,
        "friction_torque": CRANK_FRICTION_MEAN_PRESSURE_PA * displacement_litres / 1000.0 / (4.0 * math.pi),
        "throttle_cfm": throttle_cfm(engine, displacement_ci),
        "closed_throttle_plate_position": closed_throttle_plate_position(
            engine, displacement_ci, throttle_cfm(engine, displacement_ci)),
        "plenum_volume": (DIESEL_PLENUM_VOLUME_TO_DISPLACEMENT if engine["fuel"] in ("diesel", "multifuel")
                          else PLENUM_VOLUME_TO_DISPLACEMENT) * displacement_litres / 1000.0,
        "exhaust_pipe": pipe, "exhaust_outlet_cfm": pipe_flow_cfm(pipe),
        "exhaust_length": exhaust_length_m(car),
        "primary_tube_length": PRIMARY_LENGTH_BY_MANIFOLD_M[car["exhaust"]["manifold"]],
        "simulation_frequency": max(MINIMUM_SIMULATION_FREQUENCY_HZ, round(
            SIMULATION_FREQUENCY_PER_REDLINE_RPM * engine["redline_rpm"], -3)),
    }


def rated_peak_torque_nm(engine):
    if engine.get("torque_nm"):
        return engine["torque_nm"]
    power_w = engine["power_hp"] * 745.7
    return TORQUE_RISE_WHEN_TORQUE_UNKNOWN * power_w / (engine["power_rpm"] * 2 * math.pi / 60)


def boost(engine, derived):
    """Full-load boost the dyno and the mod apply to the intake, or None."""
    if engine["aspiration"] == "NA" and engine["cycle"] == 4:
        return None
    displacement = derived["displacement_litres"] / 1000.0
    radians_per_cycle = 2 * math.pi * (2 if engine["cycle"] == 4 else 1)
    rated_bmep = radians_per_cycle * rated_peak_torque_nm(engine) / displacement
    ratio = rated_bmep / UNBOOSTED_MODEL_BMEP_PA[(engine["fuel"], engine["cycle"])]
    minimum = TWO_STROKE_MINIMUM_SCAVENGE_PRESSURE_RATIO if engine["cycle"] == 2 else BOOST_PRESSURE_RATIO_LIMITS[0]
    ratio = min(max(ratio, minimum), BOOST_PRESSURE_RATIO_LIMITS[1])
    torque_rpm = engine.get("torque_rpm") or 0.6 * engine["power_rpm"]
    # Detroit turbo two-strokes keep a Roots blower: boost from idle.
    exhaust_driven = engine["aspiration"] in ("turbo", "twin-turbo") and engine["cycle"] == 4
    compressed_k = AMBIENT_K * (1 + (ratio ** 0.2857 - 1) / COMPRESSOR_EFFICIENCY)
    return {
        "kind": engine["aspiration"],
        "full_load_pressure_ratio": round(ratio, 3),
        "boost_start_rpm": round(TURBO_BOOST_STARTS_AT_TORQUE_RPM_FRACTION * torque_rpm) if exhaust_driven else 0,
        "full_boost_rpm": round(torque_rpm),
        "charge_temperature_k": round(min(compressed_k, INTERCOOLER_OUTLET_K) if engine.get("intercooled") else compressed_k, 1),
        # A two-stroke's crankcase or Roots blower pumps at any throttle.
        "follows_throttle": 0 if engine["cycle"] == 2 else 1,
    }


def not_modelled(engine):
    gaps = []
    if engine["cycle"] == 2:
        gaps.append("two-stroke: no crankcase model, scavenge pressure fixed by rule")
    if engine["fuel"] == "diesel":
        gaps.append("compression ignition (spark at injection timing)")
    if engine["aspiration"] != "NA":
        gaps.append(f"{engine['aspiration']}: boost from rated torque, no lag or wastegate")
    return gaps


def flow_function(name, event):
    diameter_m, valve_count, lift_m = event["diameter"], event["count"], event["lift"]
    lines = [f"    function {name}(50 * units.thou)"]
    steps = math.ceil(lift_m / 0.00127) + 2
    for i in range(steps + 1):
        lift = i * 0.00127
        cfm = valve_flow_cfm(diameter_m, lift, valve_count, event.get("side_valve", False))
        lines.append(f"    {name}.add_sample({i * 50} * units.thou, k_28inH2O({cfm:.2f}))")
    return lines


def engine_script(engine, car):
    d = derive(engine, car)
    fire = firing_angles_deg(engine)
    banks_deg = bank_angles_deg(engine)
    banks = cylinders_by_bank(engine, fire, banks_deg)
    reference = banks_deg[0]
    # A "dual" layout keeps one pipe per bank until the silencer or outlet.
    exhaust_count = exhaust_count_for(engine, car)
    diesel = engine["fuel"] in ("diesel", "multifuel")
    redline = engine["redline_rpm"]
    out = ["// mtes-real-spec-profile: 1"] + [
           'import "engine_sim.mr"', "", "units units()", "constants constants()", "impulse_response_library ir_lib()",
           ""] + flame_speed_node(engine)

    out += ["public node motor_town_engine {", "    alias output __out: engine;", ""]
    out += [f"    engine engine(",
            f"        name: \"{ascii_script_text(engine['name'])}\",",
            f"        starter_torque: 200 * units.lb_ft,",
            f"        starter_speed: 200 * units.rpm,",
            f"        redline: {redline} * units.rpm,",
            f"        throttle_gamma: 2.0,",
            f"        fuel: {FUEL_SCRIPT[engine['fuel']]},",
            f"        simulation_frequency: {d['simulation_frequency']:.0f}",
            "    )", ""]

    crank_moment = 0.75 * d["crank_mass"] * d["stroke"] ** 2
    flywheel_moment = 0.5 * d["flywheel_mass"] * d["flywheel_radius"] ** 2
    out += [f"    crankshaft c0(",
            f"        throw: {d['stroke'] / 2:.6f} * units.m,",
            f"        flywheel_mass: {d['flywheel_mass']:.3f} * units.kg,",
            f"        mass: {d['crank_mass']:.3f} * units.kg,",
            f"        friction_torque: {d['friction_torque']:.3f} * units.N * units.m,",
            f"        moment_of_inertia: {crank_moment + flywheel_moment:.6f} * units.kg * units.m * units.m,",
            f"        position_x: 0.0, position_y: 0.0,",
            f"        tdc: {90.0 + reference:.4f} * units.deg",
            "    )"]
    for cylinder in range(1, engine["cylinders"] + 1):
        bank_index = next(i for i, bank in enumerate(banks) if cylinder in bank)
        angle = journal_angle_deg(fire[cylinder], banks_deg[bank_index], reference)
        out.append(f"    rod_journal rj{cylinder}(angle: {angle:.4f} * units.deg)")
        out.append(f"    c0.add_rod_journal(rj{cylinder})")
    out.append("    engine.add_crankshaft(c0)")
    out.append("")

    rod_moment = d["rod_mass"] * d["rod"] ** 2 / 12.0
    out += [f"    piston_parameters piston_params(mass: {d['piston_mass'] * 1000:.1f} * units.g,",
            f"        compression_height: {d['compression_height']:.6f} * units.m,",
            f"        wrist_pin_position: 0.0, displacement: 0.0)",
            f"    connecting_rod_parameters rod_params(mass: {d['rod_mass'] * 1000:.1f} * units.g,",
            f"        moment_of_inertia: {rod_moment:.8f} * units.kg * units.m * units.m,",
            f"        center_of_mass: 0.0, length: {d['rod']:.6f} * units.m)",
            f"    intake intake(",
            f"        plenum_volume: {d['plenum_volume'] * 1000:.4f} * units.L,",
            f"        plenum_cross_section_area: {d['intake_runner_area'] * engine['cylinders'] * 1e4:.3f} * units.cm2,",
            f"        intake_flow_rate: k_carb({d['throttle_cfm']:.1f}),",
            f"        runner_flow_rate: k_carb({area_flow_cfm(d['intake_runner_area']):.1f}),",
            f"        molecular_afr: {intake_molecular_afr(engine):.4f},",
            f"        runner_length: {INTAKE_RUNNER_LENGTH_M} * units.m,",
            f"        idle_flow_rate: k_carb(0.0),",
            f"        idle_throttle_plate_position: {d['closed_throttle_plate_position']:.5f},",
            f"        velocity_decay: 0.5)",
            f"    exhaust_system_parameters exhaust_params(",
            f"        collector_cross_section_area: {math.pi * d['exhaust_pipe'] ** 2 / 4 * 1e4:.3f} * units.cm2,",
            f"        length: {d['exhaust_length']:.3f} * units.m,",
            f"        outlet_flow_rate: k_carb({d['exhaust_outlet_cfm']:.1f}),",
            f"        primary_tube_length: {d['primary_tube_length']:.3f} * units.m,",
            f"        primary_flow_rate: k_carb({area_flow_cfm(d['exhaust_runner_area']):.1f}),",
            f"        velocity_decay: 1.0, audio_volume: 1.0)"]
    for index in range(exhaust_count):
        out.append(f"    exhaust_system exhaust{index}(exhaust_params, impulse_response: {exhaust_impulse_response(car)})")
    out.append("")

    for side in ("intake", "exhaust"):
        event = d[f"{side}_event"]
        out += flow_function(f"{side}_flow", event)
        out += [f"    harmonic_cam_lobe {side}_lobe(duration_at_50_thou: {event['duration']:.2f} * units.deg,",
                f"        gamma: 1.1, lift: {event['lift']:.6f} * units.m, steps: 256)"]
    lobes_per_cycle = 1 if engine["cycle"] == 4 else 2
    out.append("")

    pitch = CYLINDER_PITCH_TO_BORE * d["bore"]
    deck = d["stroke"] / 2 + d["rod"] + d["compression_height"]
    for bank_index, (bank, bank_deg) in enumerate(zip(banks, banks_deg)):
        exhaust = f"exhaust{bank_index if exhaust_count == 2 else 0}"
        out += [f"    camshaft intake_cam{bank_index}(advance: 0.0, base_radius: 0.5 * units.inch, "
                f"lobe_profile: intake_lobe, lobes_per_cycle: {lobes_per_cycle})",
                f"    camshaft exhaust_cam{bank_index}(advance: 0.0, base_radius: 0.5 * units.inch, "
                f"lobe_profile: exhaust_lobe, lobes_per_cycle: {lobes_per_cycle})",
                f"    cylinder_bank b{bank_index}(angle: {bank_deg:.4f} * units.deg, bore: {d['bore']:.6f} * units.m,",
                f"        deck_height: {deck:.6f} * units.m)"]
        for position, cylinder in enumerate(bank):
            out += [f"    intake_cam{bank_index}.add_lobe(({d['intake_event']['centre']} + {fire[cylinder]:.4f}) * units.deg)",
                    f"    exhaust_cam{bank_index}.add_lobe(({d['exhaust_event']['centre']} + {fire[cylinder]:.4f}) * units.deg)",
                    f"    ignition_wire wire{cylinder}()",
                    f"    b{bank_index}.add_cylinder(",
                    f"        piston: piston(piston_params, blowby: k_28inH2O(0.0)),",
                    f"        connecting_rod: connecting_rod(rod_params),",
                    f"        rod_journal: rj{cylinder}, intake: intake, exhaust_system: {exhaust},",
                    f"        ignition_wire: wire{cylinder}, sound_attenuation: 1.0,",
                    f"        primary_length: {(len(bank) - 1 - position) * pitch + 0.05:.4f} * units.m)"]
        out += [f"    b{bank_index}.set_cylinder_head(generic_cylinder_head(",
                f"        chamber_volume: {d['chamber_volume'] * 1e6:.3f} * units.cc,",
                f"        intake_runner_volume: {d['intake_runner_area'] * d['port_length'] * 1e6:.3f} * units.cc,",
                f"        intake_runner_cross_section_area: {d['intake_runner_area'] * 1e4:.4f} * units.cm2,",
                f"        exhaust_runner_volume: {exhaust_runner_volume_m3(d) * 1e6:.3f} * units.cc,",
                f"        exhaust_runner_cross_section_area: {d['exhaust_runner_area'] * 1e4:.4f} * units.cm2,",
                f"        intake_port_flow: intake_flow, exhaust_port_flow: exhaust_flow,",
                f"        valvetrain: standard_valvetrain(intake_camshaft: intake_cam{bank_index}, exhaust_camshaft: exhaust_cam{bank_index}),",
                f"        flip_display: {'true' if bank_index else 'false'}))",
                f"    engine.add_cylinder_bank(b{bank_index})", ""]

    out.append("    function timing_curve(1000 * units.rpm)")
    full_rpm = SPARK_FULL_ADVANCE_AT_REDLINE_FRACTION * redline
    measured_best_advance = SPARK_ADVANCE_CALIBRATION.get(engine["id"])
    for rpm in range(0, int(redline) + 2001, 500):
        if measured_best_advance:
            advance = interpolate(measured_best_advance, rpm)
        elif diesel:
            advance = DIESEL_INJECTION_ADVANCE_DEG
        else:
            advance = SPARK_ADVANCE_IDLE_DEG + (SPARK_ADVANCE_FULL_DEG - SPARK_ADVANCE_IDLE_DEG) \
                * min(1.0, max(0.0, (rpm - 1000.0) / (full_rpm - 1000.0)))
        out.append(f"    timing_curve.add_sample({rpm} * units.rpm, {advance:.2f} * units.deg)")
    out.append(f"    ignition_module ignition_module(timing_curve: timing_curve, "
               f"rev_limit: {redline + 300} * units.rpm, limiter_duration: 0.1, "
               f"sparks_per_cycle: {lobes_per_cycle})")
    for cylinder in engine["firing_order"]:
        out.append(f"    ignition_module.connect_wire(wire{cylinder}, {fire[cylinder]:.4f} * units.deg)")
    out += ["    engine.add_ignition_module(ignition_module)", "}", ""]

    # The dynamometer holds the crank; vehicle and gearbox only satisfy the compiler.
    out += ["public node main {",
            "    set_engine(motor_town_engine())",
            "    set_vehicle(vehicle(mass: 1500 * units.kg, drag_coefficient: 0.35,",
            "        cross_sectional_area: 2.0 * units.m * units.m, diff_ratio: 3.42,",
            "        tire_radius: 0.33 * units.m, rolling_resistance: 200 * units.N))",
            "    set_transmission(transmission(max_clutch_torque: 1000 * units.lb_ft).add_gear(1.0))",
            "}", "", "main()", ""]
    return "\n".join(out), d


def main(arguments):
    output_dir = Path(arguments[0])
    output_dir.mkdir(parents=True, exist_ok=True)
    engines, cars = load_specs()
    wanted = arguments[1:] or list(engines)
    manifest = []
    for engine_id in wanted:
        engine = engines[engine_id]
        car = first_car_using(engine_id, cars)
        entry = {"engine": engine_id, "car": car["real_car"], "not_modelled": not_modelled(engine),
                 "rated": {key: engine.get(key) for key in
                           ("power_hp", "power_rpm", "torque_nm", "torque_rpm", "redline_rpm")}}
        try:
            script, derived = engine_script(engine, car)
        except NotImplementedError as error:
            entry["skipped"] = str(error)
        else:
            (output_dir / f"{engine_id}.mr").write_text(script)
            entry["script"] = f"{engine_id}.mr"
            entry["boost"] = boost(engine, derived)
            if entry["boost"]:
                (output_dir / f"{engine_id}.boost.json").write_text(json.dumps(entry["boost"]))
            entry["derived"] = {key: round(value, 6) if isinstance(value, float) else value
                                for key, value in derived.items()}
        manifest.append(entry)
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
    skipped = [entry["engine"] for entry in manifest if "skipped" in entry]
    print(f"{len(manifest) - len(skipped)} scripts, skipped {len(skipped)}: {' '.join(skipped)}")


if __name__ == "__main__":
    main(sys.argv[1:])
