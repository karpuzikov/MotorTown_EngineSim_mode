"""Write the mod's engine profiles from the real-car specs.

    python3 -I pipeline/package_mod_profiles.py

Replaces native/profiles/es_*.mr (+ .boost.json) and engine_families.tsv:
- one script per real car and engine option, with that car's exhaust; every
  rule also names the one fleet-wide exhaust response (`#exhaust=`);
- vehicle rules: each Motor Town vehicle id -> its real car's engines, the
  installed engine's horsepower picking the option of nearest rated power;
- fallback rules for vehicles not listed (traffic, new cars), by engine
  asset name, sound cue and redline, onto representative real engines.
"""

import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_engine_scripts as generator  # noqa: E402

PROFILES_DIR = Path(__file__).resolve().parents[1] / "native" / "profiles"
HANDMADE_DIR = Path(__file__).resolve().parent / "handmade"
# One exhaust response for every vehicle (pillar 3), made by tune_impulse_to_recording.py.
FLEET_EXHAUST_SOURCE = Path(__file__).resolve().parent / "fleet_exhaust_response.wav"
EXHAUST_DIR = PROFILES_DIR / "sound-library" / "mtes-exhaust"
FLEET_EXHAUST_SUFFIX = "#exhaust=mtes-exhaust/fleet.wav"   # path relative to assets/sound-library

# Vehicles not listed: Motor Town engine asset / cue / max-rpm patterns
# (kept from the previous profile set) -> a representative real engine.
FALLBACK_RULES = [
    ("asset", r"electric|battery|e-?motor|(^|[^a-z])ev([^a-z]|$)", None, None),
    ("asset", r"2jz", "toyota_2jz_gte", None),
    ("asset", r"rb2[0568]", "nissan_rb26dett", None),
    ("asset", r"(^|[^a-z0-9])[sn]5[02-8]([^0-9]|$)|b58", "bmw_n55_m2", None),
    ("asset", r"smal+-?block|302", "ford_302_windsor", "0-207"),
    ("asset", r"smal+-?block|302", "ford_351w", "208-100000"),
    ("asset", r"hemi|392", "chrysler_hemi_57", None),
    ("asset", r"81bb|454|427|big-?block", "chrysler_440_rb_police", None),
    ("asset", r"v10", "ford_68_triton_v10", None),
    ("asset", r"v12|ferrari_275", "lambo_l539_65", None),
    ("asset", r"v6", "buick_38_lc2", None),
    ("asset", r"(^|[^a-z0-9])v8", "chevy_350_l48", None),
    ("asset", r"kart", "kart_100_2t", None),
    ("asset", r"scooter|2-?stroke|moped", "vespa_150_2t", None),
    ("asset", r"bike_?i4", "yamaha_cp4_998", None),
    ("asset", r"bike|(^|[^a-z0-9])h2_", "honda_cb250_twin", None),
    ("asset", r"i4sport", "mazda_b6ze", None),
    ("asset", r"(^|[^a-z0-9])[il]4|inline-?4", "ford_14_sigma", None),
    ("asset", r"(^|[^a-z0-9])[il]6|inline-?6", "bmw_n55_m2", None),
    ("asset", r"(^|[^a-z0-9])[il]5", "volvo_b5254t3", None),
    ("asset", r"heavymachine", "volvo_d11", "0-396"),
    ("asset", r"heavymachine", "volvo_d13", "397-100000"),
    ("asset", r"heavyduty", "iveco_cursor8", "0-301"),
    ("asset", r"heavyduty", "cummins_isx15", "302-487"),
    ("asset", r"heavyduty", "volvo_d16", "488-100000"),
    ("asset", r"mediumduty", "navistar_dt466", "0-217"),
    ("asset", r"mediumduty", "man_d0836_loh", "218-269"),
    ("asset", r"mediumduty", "iveco_cursor8", "270-100000"),
    ("asset", r"bus", "iveco_f1c_30", "0-179"),
    ("asset", r"bus", "man_d0836_loh", "180-262"),
    ("asset", r"bus", "iveco_cursor8", "263-346"),
    ("asset", r"bus", "volvo_d11", "347-100000"),
    ("asset", r"diesel|truck", "man_d0836_loh", None),
    ("cue", r"/electric/", None, None),
    ("cue", r"2stroke|chainsaw", "vespa_150_2t", None),
    ("cue", r"/bike/i4", "yamaha_cp4_998", None),
    ("cue", r"/bike/", "honda_cb250_twin", None),
    ("cue", r"i4sport", "mazda_b6ze", None),
    ("cue", r"v6sport", "buick_38_lc2", None),
    ("cue", r"/v12/", "lambo_l539_65", None),
    ("cue", r"truck|midduty", "navistar_dt466", None),
    ("maxrpm", "11000-40000", "yamaha_cp4_998", None),
    ("maxrpm", "7600-10999", "mazda_b6ze", None),
    ("maxrpm", "0-3300", "cummins_isx15", None),
    ("maxrpm", "3301-4800", "chevy_350_truck", None),
    ("maxrpm", "4801-7599", "chevy_350_l48", None),
]


def vehicle_key(game_id):
    # vehicle_profile.cpp matches the blueprint class lower-cased without "_".
    # shortcut: motortown.info ids, assumed to prefix the blueprint class
    # (a version digit dropped: "Trophy2" -> "trophy", not "FL1" or "4x2"); a miss falls through
    # to the asset/cue/maxrpm rules. Check in game.
    key = game_id.replace("_", "").lower()
    letters = re.fullmatch(r"([a-z]{5,})[0-9]+", key)
    return letters.group(1) if letters else key


def horsepower_ranges(engines):
    """Each engine option owns the game horsepower nearest its rated power."""
    ordered = sorted(engines, key=lambda engine: engine["power_hp"])
    bounds = [round((a["power_hp"] + b["power_hp"]) / 2) for a, b in zip(ordered, ordered[1:])]
    lows = [0] + [bound + 1 for bound in bounds]
    highs = bounds + [100000]
    return [(engine, f"{low}-{high}") for engine, low, high in zip(ordered, lows, highs)]


def write_script(engine, car, name):
    """The engine as written by hand in pipeline/handmade (real specs, Engine
    Simulator's own style) when one exists, else generated."""
    handmade = HANDMADE_DIR / f"{name}.mr"
    if handmade.is_file():
        (PROFILES_DIR / f"{name}.mr").write_text(handmade.read_text())
        return f"assets/{name}.mr"
    script, derived = generator.engine_script(engine, car)
    (PROFILES_DIR / f"{name}.mr").write_text(script)
    boost = generator.boost(engine, derived)
    if boost:
        (PROFILES_DIR / f"{name}.boost.json").write_text(generator.json.dumps(boost))
    return f"assets/{name}.mr"


def main():
    engines, cars = generator.load_specs()
    for old in (list(PROFILES_DIR.glob("es_*.mr")) + list(PROFILES_DIR.glob("es_*.boost.json"))
                + list(EXHAUST_DIR.glob("*.wav"))):
        old.unlink()
    EXHAUST_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(FLEET_EXHAUST_SOURCE, EXHAUST_DIR / "fleet.wav")
    lines = [
        "# Generated by pipeline/package_mod_profiles.py from pipeline/real_*.json. First match wins.",
        "# vehicle: Motor Town vehicle (blueprint class, lower case, no underscores) -> its real",
        "#          car's engine options; the 4th column is the installed engine's horsepower.",
        "# asset/cue/maxrpm: engine data of vehicles not listed (traffic, new cars); '-' keeps stock.",
    ]
    vehicle_rules = []
    for car in cars:
        if car.get("keep_stock"):
            for game_id in car["game_ids"]:
                vehicle_rules.append((vehicle_key(game_id), f"vehicle\t^{vehicle_key(game_id)}\t-"))
            continue
        options = [engines[engine_id] for engine_id in car["engines"]]
        scripts = {engine["id"]: write_script(engine, car, f"es_{engine['id']}__{generator.car_slug(car)}")
                   for engine in options}
        for game_id in car["game_ids"]:
            key = vehicle_key(game_id)
            if len(options) == 1:
                vehicle_rules.append((key, f"vehicle\t^{key}\t{scripts[options[0]['id']]}{FLEET_EXHAUST_SUFFIX}"))
                continue
            for engine, horsepower in horsepower_ranges(options):
                vehicle_rules.append((key, f"vehicle\t^{key}\t{scripts[engine['id']]}{FLEET_EXHAUST_SUFFIX}\t{horsepower}"))
    # Longer keys first: "monarchlimo" must not fall to "^monarch".
    vehicle_rules.sort(key=lambda rule: -len(rule[0]))
    lines += [rule for _, rule in vehicle_rules]
    fallback_scripts = {}
    for field, pattern, engine_id, horsepower in FALLBACK_RULES:
        if engine_id and engine_id not in fallback_scripts:
            fallback_scripts[engine_id] = write_script(
                engines[engine_id], generator.first_car_using(engine_id, cars), f"es_{engine_id}")
        target = fallback_scripts[engine_id] + FLEET_EXHAUST_SUFFIX if engine_id else "-"
        lines.append("\t".join([field, pattern, target] + ([horsepower] if horsepower else [])))
    (PROFILES_DIR / "engine_families.tsv").write_text("\n".join(lines) + "\n")
    print(f"{len(list(PROFILES_DIR.glob('es_*.mr')))} scripts, {len(lines)} manifest lines")


if __name__ == "__main__":
    main()
