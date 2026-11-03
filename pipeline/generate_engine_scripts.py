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
import os
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
VALVE_LIFT_TO_DIAMETER = 0.25
VALVE_THROAT_AREA_FRACTION = 0.85                # valve area left beside the stem
PORT_DISCHARGE_COEFFICIENT = 0.65
RUNNER_AREA_TO_VALVE_AREA = 1.3
HEAD_PORT_LENGTH_TO_BORE = 0.5
CAM_DURATION_BASE_DEG = 170.0                    # duration at 0.050" lift
CAM_DURATION_PER_PISTON_SPEED_DEG = 3.3          # per m/s mean piston speed at rated power
CAM_DURATION_LIMITS_DEG = (190.0, 260.0)
CAM_LOBE_SEPARATION_DEG = 112.0
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
THROTTLE_CFM_MARGIN = 1.2
PLENUM_VOLUME_TO_DISPLACEMENT = 1.0
INTAKE_RUNNER_LENGTH_M = 0.25
CYLINDER_PITCH_TO_BORE = 1.15
PRIMARY_LENGTH_BY_MANIFOLD_M = {"cast-log": 0.20, "cast": 0.30, "turbo": 0.30, "tubular": 0.75}
PIPE_DISCHARGE_COEFFICIENT = 0.8                 # straight pipe or runner, not a valve
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
FLAME_SPEED_SCALE = float(os.environ.get("MOTOR_TOWN_ENGINE_SIM_FLAME_SPEED_SCALE", "1.0"))
FLAME_SPEED_ARGUMENT = "turbulence_to_flame_speed_ratio: motor_town_flame_speed()"
FUEL_SCRIPT = {
    "petrol": "fuel(name: \"Gasoline\", " + FLAME_SPEED_ARGUMENT + ")",
    "multifuel": "fuel(name: \"Gasoline\", " + FLAME_SPEED_ARGUMENT + ")",
    "petrol-oil": "fuel(name: \"Gasoline\", " + FLAME_SPEED_ARGUMENT + ")",
    # Diesel C12H23: 167 g/mol, 17.75 mol O2 per mol fuel, 45.5 kJ/g.
    "diesel": ("fuel(name: \"Diesel\", molecular_mass: 167 * units.g, "
               "energy_density: 45.5 * units.kJ / units.g, "
               "density: 0.832 * units.kg / units.L, molecular_afr: 17.75, " + FLAME_SPEED_ARGUMENT + ")"),
}


def flame_speed_node():
    """Engine Simulator's default turbulence-to-flame-speed curve, scaled."""
    samples = [(0.0, 3.0)] + [(x, 1.5 * x) for x in range(5, 50, 5)]
    lines = ["private node motor_town_flame_speed {", "    alias output __out:", "        function(5.0)"]
    lines += [f"            .add_sample({x:.1f}, {FLAME_SPEED_SCALE * y:.4f})" for x, y in samples]
    lines[-1] += ";"
    return lines + ["}", ""]


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
    if engine["layout"] == "I":
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


def valve_flow_cfm(diameter_m, lift_m, valve_count):
    """Flow bench figure at 28 inH2O: curtain area until the throat chokes."""
    curtain = math.pi * diameter_m * lift_m
    throat = VALVE_THROAT_AREA_FRACTION * math.pi * diameter_m ** 2 / 4.0
    velocity = math.sqrt(2.0 * PRESSURE_28_INCH_H2O_PA / AIR_DENSITY_KG_M3)
    return (valve_count * PORT_DISCHARGE_COEFFICIENT * min(curtain, throat)
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
    if engine["fuel"] == "diesel":
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
    power_rpm = engine.get("power_rpm") or 0.8 * engine["redline_rpm"]
    piston_speed = 2.0 * stroke * power_rpm / 60.0
    duration = min(max(CAM_DURATION_BASE_DEG + CAM_DURATION_PER_PISTON_SPEED_DEG * piston_speed,
                       CAM_DURATION_LIMITS_DEG[0]), CAM_DURATION_LIMITS_DEG[1])
    rod = (engine.get("rod_mm") or 0) / 1000.0 or ROD_TO_STROKE_RATIO * stroke
    piston_mass = PISTON_MASS_G_PER_BORE_CM3 * (bore * 100.0) ** 3 / 1000.0
    intake_valve_area = intake_valves * math.pi * intake_valve ** 2 / 4.0
    exhaust_valve_area = exhaust_valves * math.pi * exhaust_valve ** 2 / 4.0
    displacement_ci = displacement_litres * 61.0237
    pipe = car["exhaust"]["pipe_mm"] / 1000.0
    return {
        "bore": bore, "stroke": stroke, "rod": rod,
        "compression_height": COMPRESSION_HEIGHT_TO_BORE * bore,
        "chamber_volume": swept_per_cylinder / (compression - 1.0),
        "displacement_litres": displacement_litres,
        "intake_valves": intake_valves, "exhaust_valves": exhaust_valves,
        "intake_valve": intake_valve, "exhaust_valve": exhaust_valve,
        "lift": lift, "cam_duration": duration,
        "intake_runner_area": RUNNER_AREA_TO_VALVE_AREA * intake_valve_area,
        "exhaust_runner_area": RUNNER_AREA_TO_VALVE_AREA * exhaust_valve_area,
        "port_length": HEAD_PORT_LENGTH_TO_BORE * bore,
        "intake_port_peak_cfm": valve_flow_cfm(intake_valve, lift, intake_valves),
        "exhaust_port_peak_cfm": valve_flow_cfm(exhaust_valve, lift, exhaust_valves),
        "piston_mass": piston_mass, "rod_mass": ROD_MASS_TO_PISTON_MASS * piston_mass,
        "crank_mass": CRANK_MASS_KG_PER_LITRE * displacement_litres,
        "flywheel_mass": FLYWHEEL_MASS_KG_AT_1_LITRE * displacement_litres ** FLYWHEEL_MASS_EXPONENT,
        "flywheel_radius": FLYWHEEL_RADIUS_M_AT_1_LITRE * displacement_litres ** FLYWHEEL_RADIUS_EXPONENT,
        "friction_torque": CRANK_FRICTION_MEAN_PRESSURE_PA * displacement_litres / 1000.0 / (4.0 * math.pi),
        "throttle_cfm": THROTTLE_CFM_MARGIN * displacement_ci * engine["redline_rpm"] / 3456.0,
        "plenum_volume": PLENUM_VOLUME_TO_DISPLACEMENT * displacement_litres / 1000.0,
        "exhaust_pipe": pipe, "exhaust_outlet_cfm": pipe_flow_cfm(pipe),
        "exhaust_length": exhaust_length_m(car),
        "primary_tube_length": PRIMARY_LENGTH_BY_MANIFOLD_M[car["exhaust"]["manifold"]],
        "simulation_frequency": max(MINIMUM_SIMULATION_FREQUENCY_HZ, round(
            SIMULATION_FREQUENCY_PER_REDLINE_RPM * engine["redline_rpm"], -3)),
    }


def not_modelled(engine):
    gaps = []
    if engine["cycle"] == 2:
        gaps.append("two-stroke cycle")
    if engine["fuel"] == "diesel":
        gaps.append("compression ignition (spark at injection timing)")
    if engine["aspiration"] != "NA":
        gaps.append(f"{engine['aspiration']} boost")
    return gaps


def flow_function(name, peak_cfm, diameter_m, valve_count, lift_m):
    lines = [f"    function {name}(50 * units.thou)"]
    steps = math.ceil(lift_m / 0.00127) + 2
    for i in range(steps + 1):
        lift = i * 0.00127
        cfm = valve_flow_cfm(diameter_m, lift, valve_count)
        lines.append(f"    {name}.add_sample({i * 50} * units.thou, k_28inH2O({cfm:.2f}))")
    return lines


def engine_script(engine, car):
    if engine["cycle"] != 4:
        raise NotImplementedError(f"{engine['id']}: two-stroke cycle needs new simulation code")
    d = derive(engine, car)
    fire = firing_angles_deg(engine)
    banks_deg = bank_angles_deg(engine)
    banks = cylinders_by_bank(engine, fire, banks_deg)
    reference = banks_deg[0]
    # A "dual" layout keeps one pipe per bank until the silencer or outlet.
    exhaust_count = 2 if len(banks) == 2 and car["exhaust"]["layout"] == "dual" else 1
    diesel = engine["fuel"] == "diesel"
    redline = engine["redline_rpm"]
    out = ['import "engine_sim.mr"', "", "units units()", "constants constants()",
           "impulse_response_library ir_lib()", ""] + flame_speed_node()

    out += ["public node motor_town_engine {", "    alias output __out: engine;", ""]
    out += [f"    engine engine(",
            f"        name: \"{engine['name']}\",",
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
            f"        idle_throttle_plate_position: 0.995,",
            f"        velocity_decay: 0.5)",
            f"    exhaust_system_parameters exhaust_params(",
            f"        collector_cross_section_area: {math.pi * d['exhaust_pipe'] ** 2 / 4 * 1e4:.3f} * units.cm2,",
            f"        length: {d['exhaust_length']:.3f} * units.m,",
            f"        outlet_flow_rate: k_carb({d['exhaust_outlet_cfm']:.1f}),",
            f"        primary_tube_length: {d['primary_tube_length']:.3f} * units.m,",
            f"        primary_flow_rate: k_carb({area_flow_cfm(d['exhaust_runner_area']):.1f}),",
            f"        velocity_decay: 1.0, audio_volume: 1.0)"]
    for index in range(exhaust_count):
        out.append(f"    exhaust_system exhaust{index}(exhaust_params, impulse_response: ir_lib.default_0)")
    out.append("")

    out += flow_function("intake_flow", d["intake_port_peak_cfm"], d["intake_valve"],
                         d["intake_valves"], d["lift"])
    out += flow_function("exhaust_flow", d["exhaust_port_peak_cfm"], d["exhaust_valve"],
                         d["exhaust_valves"], d["lift"])
    out += [f"    harmonic_cam_lobe cam_lobe(duration_at_50_thou: {d['cam_duration']:.2f} * units.deg,",
            f"        gamma: 1.1, lift: {d['lift']:.6f} * units.m, steps: 256)", ""]

    pitch = CYLINDER_PITCH_TO_BORE * d["bore"]
    deck = d["stroke"] / 2 + d["rod"] + d["compression_height"]
    for bank_index, (bank, bank_deg) in enumerate(zip(banks, banks_deg)):
        exhaust = f"exhaust{bank_index if exhaust_count == 2 else 0}"
        out += [f"    camshaft intake_cam{bank_index}(advance: 0.0, base_radius: 0.5 * units.inch, lobe_profile: cam_lobe)",
                f"    camshaft exhaust_cam{bank_index}(advance: 0.0, base_radius: 0.5 * units.inch, lobe_profile: cam_lobe)",
                f"    cylinder_bank b{bank_index}(angle: {bank_deg:.4f} * units.deg, bore: {d['bore']:.6f} * units.m,",
                f"        deck_height: {deck:.6f} * units.m)"]
        for position, cylinder in enumerate(bank):
            centre = CAM_LOBE_SEPARATION_DEG
            out += [f"    intake_cam{bank_index}.add_lobe((360 + {centre} + {fire[cylinder]:.4f}) * units.deg)",
                    f"    exhaust_cam{bank_index}.add_lobe((360 - {centre} + {fire[cylinder]:.4f}) * units.deg)",
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
                f"        exhaust_runner_volume: {d['exhaust_runner_area'] * d['port_length'] * 1e6:.3f} * units.cc,",
                f"        exhaust_runner_cross_section_area: {d['exhaust_runner_area'] * 1e4:.4f} * units.cm2,",
                f"        intake_port_flow: intake_flow, exhaust_port_flow: exhaust_flow,",
                f"        valvetrain: standard_valvetrain(intake_camshaft: intake_cam{bank_index}, exhaust_camshaft: exhaust_cam{bank_index}),",
                f"        flip_display: {'true' if bank_index else 'false'}))",
                f"    engine.add_cylinder_bank(b{bank_index})", ""]

    out.append("    function timing_curve(1000 * units.rpm)")
    full_rpm = SPARK_FULL_ADVANCE_AT_REDLINE_FRACTION * redline
    for rpm in range(0, int(redline) + 2001, 500):
        if diesel:
            advance = DIESEL_INJECTION_ADVANCE_DEG
        else:
            advance = SPARK_ADVANCE_IDLE_DEG + (SPARK_ADVANCE_FULL_DEG - SPARK_ADVANCE_IDLE_DEG) \
                * min(1.0, max(0.0, (rpm - 1000.0) / (full_rpm - 1000.0)))
        out.append(f"    timing_curve.add_sample({rpm} * units.rpm, {advance:.2f} * units.deg)")
    out.append(f"    ignition_module ignition_module(timing_curve: timing_curve, "
               f"rev_limit: {redline + 300} * units.rpm, limiter_duration: 0.1)")
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
            entry["derived"] = {key: round(value, 6) for key, value in derived.items()}
        manifest.append(entry)
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
    skipped = [entry["engine"] for entry in manifest if "skipped" in entry]
    print(f"{len(manifest) - len(skipped)} scripts, skipped {len(skipped)}: {' '.join(skipped)}")


if __name__ == "__main__":
    main(sys.argv[1:])
