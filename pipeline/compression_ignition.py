"""Turn the mod's diesel scripts into compression-ignition ones (Engine Simulator's diesel_injection_pump).

A diesel script (fuel with a lean_ignition_limit) is a petrol-style engine with a lean fuel. Engine Simulator's
compression ignition meters the fuel at the pump and lets the compressed air light it, so the pump governs idle and
top speed itself and the host does not meter fuel.

    python3 -I pipeline/compression_ignition.py native/profiles

Rewrites native/profiles/es_*.mr in place (idempotent). sync_engine_voice_engines.py calls convert_script too.
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_engine_scripts as generator  # noqa: E402

ENGINE_SIM_OXYGEN_MOLES_PER_FUEL_MOLE = 12.5  # GasSystem::react burns every fuel with octane's ratio
FUEL_CALL = re.compile(r"\bfuel\(")
FUEL_MOLECULAR_MASS = re.compile(r"molecular_mass:\s*([\d.]+)\s*\*\s*units\.g")
FUEL_MOLECULAR_AFR = re.compile(r"molecular_afr:\s*([\d.]+)")
IGNITION_MODULE = re.compile(r"ignition_module ignition_module\((.*?)\)", re.DOTALL)
SPARKS_PER_CYCLE = re.compile(r"sparks_per_cycle:\s*(\d+)")
REDLINE = re.compile(r"\bredline:\s*(\d+)\s*\*\s*units\.rpm")


def matching_parenthesis(text, opening_index):
    depth = 0
    for index in range(opening_index, len(text)):
        depth += {"(": 1, ")": -1}.get(text[index], 0)
        if depth == 0:
            return index
    raise ValueError("unbalanced parenthesis in fuel(...)")


def convert_fuel(script):
    """Same heat per mole of oxygen, with Engine Simulator's fixed 12.5 mol O2 per mol fuel."""
    start = FUEL_CALL.search(script).end() - 1
    end = matching_parenthesis(script, start)
    call = script[start:end + 1]
    mass = float(FUEL_MOLECULAR_MASS.search(call).group(1))
    afr = float(FUEL_MOLECULAR_AFR.search(call).group(1))
    call = FUEL_MOLECULAR_MASS.sub(
        f"molecular_mass: {mass * ENGINE_SIM_OXYGEN_MOLES_PER_FUEL_MOLE / afr:.1f} * units.g", call)
    call = FUEL_MOLECULAR_AFR.sub(f"molecular_afr: {ENGINE_SIM_OXYGEN_MOLES_PER_FUEL_MOLE}", call)
    return script[:start] + call + script[end + 1:]


def convert_script(script, engine):
    if "diesel_injection_pump" in script or "lean_ignition_limit" not in script:
        return script
    redline = int(REDLINE.search(script).group(1))
    module = IGNITION_MODULE.search(script)
    sparks = SPARKS_PER_CYCLE.search(module.group(1)).group(1)
    pump = (f"diesel_injection_pump ignition_module(timing_curve: timing_curve, "
            f"max_fuel_per_injection: {generator.full_load_fuel_per_injection_g(engine):.5f} * units.g, "
            f"idle_speed: {generator.idle_rpm(engine):.0f} * units.rpm, governed_speed: {redline} * units.rpm, "
            f"sparks_per_cycle: {sparks})")
    script = script[:module.start()] + pump + script[module.end():]
    return convert_fuel(script)


def engine_id_of(script_path):
    return script_path.stem[len("es_"):].split("__")[0]


def main(profiles_folder):
    engines, _ = generator.load_specs()
    converted = []
    for path in sorted(Path(profiles_folder).glob("es_*.mr")):
        text = path.read_text()
        converted_text = convert_script(text, engines[engine_id_of(path)])
        if converted_text != text:
            path.write_text(converted_text)
            converted.append(path.name)
    print(f"{len(converted)} diesel scripts now compression ignition")


if __name__ == "__main__":
    main(sys.argv[1])
