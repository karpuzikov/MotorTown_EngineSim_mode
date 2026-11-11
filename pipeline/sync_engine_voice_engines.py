"""Take the engines the mod plays from EngineVoice, where every Motor Town engine is checked to start, idle and rev
and the sound was picked by ear (karpuzikov engine-voice, vendor/engine-sim/assets/engines/motortown).

EngineVoice imported this repo's generated scripts (pipeline/package_mod_profiles.py) and fixed them for the whole fleet with
one set of rules: diesels are fuel-metered (lean_ignition_limit, open intake, the MC-9's synthesizer mix, the truck exhaust
response, cycle-to-cycle variation), starters are sized to the engine and every petrol engine's idle throttle is calibrated to
idle by itself. Run this after package_mod_profiles.py; it writes into native/profiles:

- every "<car>__<engine>.mr" as "es_<engine>__<car>.mr", with the trailing main() call the mod's loader needs;
- every car-less "es_<engine>.mr" (traffic and unknown vehicles) from the first EngineVoice car that has that engine;
- the hand-made MC-9 (mc9_6v92ta.mr, fitted to the owner's recording) as the 1980 MCI MC-9's 6V92TA;
- each script's boost file mirrored (copied, or removed when EngineVoice has none);
- EngineVoice's own exhaust responses (truck_exhaust.wav, mc9_exhaust.wav) next to the scripts: Engine Simulator resolves a
  response named in a script relative to that script (in sound-library/ they were not found and every diesel was silent);
- engine_families.tsv without "#exhaust=" overrides: each script plays the exhaust response it names, as in EngineVoice.

Only scripts the mod already ships are written: the manifests name them, so a new name would never play.

    python3 pipeline/sync_engine_voice_engines.py <engine-voice>/vendor/engine-sim/assets/engines/motortown native/profiles
"""

import pathlib
import re
import shutil
import sys

HAND_MADE = {"mc9_6v92ta.mr": "es_detroit_6v92ta__1980_mci_mc_9.mr"}
EXHAUST_RESPONSES = ("truck_exhaust.wav", "mc9_exhaust.wav")
EXHAUST_OVERRIDE = re.compile(r"#exhaust=[^\t\n]*")


def write_script(source, target):
    target.write_text(source.read_text().rstrip("\n") + "\n\nmain()\n")
    source_boost, target_boost = source.with_suffix(".boost.json"), target.with_suffix(".boost.json")
    if source_boost.exists():
        shutil.copyfile(source_boost, target_boost)
    elif target_boost.exists():
        target_boost.unlink()


def main():
    engine_voice_folder, profiles_folder = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    written, skipped = [], []
    first_car_for_engine = {}
    for script in sorted(engine_voice_folder.glob("*__*.mr")):
        car_name, engine_name = script.stem.split("__", 1)
        first_car_for_engine.setdefault(engine_name, script)
        target = profiles_folder / f"es_{engine_name}__{car_name}.mr"
        if target.exists():
            write_script(script, target)
            written.append(target.name)
        else:
            skipped.append(script.name)
    for target in sorted(profiles_folder.glob("es_*.mr")):
        if "__" in target.stem:
            continue
        source = first_car_for_engine.get(target.stem[len("es_"):])
        if source is None:
            raise SystemExit(f"{target.name}: no EngineVoice engine of that name")
        write_script(source, target)
        written.append(target.name)
    for source_name, target_name in HAND_MADE.items():
        write_script(engine_voice_folder / source_name, profiles_folder / target_name)
    for response in EXHAUST_RESPONSES:
        shutil.copyfile(engine_voice_folder / response, profiles_folder / response)
    manifest = profiles_folder / "engine_families.tsv"
    manifest.write_text(EXHAUST_OVERRIDE.sub("", manifest.read_text()))

    not_from_engine_voice = sorted({p.name for p in profiles_folder.glob("es_*.mr")} - set(written) - set(HAND_MADE.values()))
    if not_from_engine_voice:
        raise SystemExit(f"left as generated (no EngineVoice version): {', '.join(not_from_engine_voice)}")
    print(f"wrote {len(written)} scripts and {len(HAND_MADE)} hand-made into {profiles_folder}")
    if skipped:
        print(f"not in the mod's manifests, skipped: {', '.join(skipped)}")


if __name__ == "__main__":
    main()
