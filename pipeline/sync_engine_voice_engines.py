"""Take the petrol engines the mod plays from EngineVoice, where every Motor Town engine is checked to start, idle and rev
and the sound was picked by ear (karpuzikov engine-voice, vendor/engine-sim/assets/engines/motortown).

EngineVoice imported this repo's generated scripts (pipeline/package_mod_profiles.py) and fixed them for the whole fleet with
one set of rules: starters are sized to the engine and every petrol engine's idle throttle is calibrated to idle by itself.
Its diesel rules are not taken: diesels are simulated exactly as petrol engines (generate_engine_scripts.simulated_as_petrol),
so their scripts stay as package_mod_profiles.py generated them. Run this after package_mod_profiles.py; it writes into
native/profiles:

- every petrol "<car>__<engine>.mr" as "es_<engine>__<car>.mr", with the trailing main() call the mod's loader needs;
- every car-less petrol "es_<engine>.mr" (traffic and unknown vehicles) from the first EngineVoice car that has that engine;
- each script's boost file mirrored (copied, or removed when EngineVoice has none);
- the EngineVoice exhaust responses a written script names (the kart's), next to the scripts: Engine Simulator resolves a
  response named in a script relative to that script;
- engine_families.tsv without "#exhaust=" overrides: each script plays the exhaust response it names, as in EngineVoice.

Only scripts the mod already ships are written: the manifests name them, so a new name would never play.

    python3 pipeline/sync_engine_voice_engines.py <engine-voice>/vendor/engine-sim/assets/engines/motortown native/profiles
"""

import pathlib
import re
import shutil
import sys

EXHAUST_OVERRIDE = re.compile(r"#exhaust=[^\t\n]*")
NAMED_RESPONSE = re.compile(r'impulse_response \w+\(filename: "([^"]+)"')


def is_engine_voice_diesel(script):
    return 'fuel(name: "Diesel"' in script.read_text()


def write_script(source, target):
    target.write_text(source.read_text().rstrip("\n") + "\n\nmain()\n")
    source_boost, target_boost = source.with_suffix(".boost.json"), target.with_suffix(".boost.json")
    if source_boost.exists():
        shutil.copyfile(source_boost, target_boost)
    elif target_boost.exists():
        target_boost.unlink()


def main():
    engine_voice_folder, profiles_folder = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    written, skipped, generated_diesels = [], [], []
    first_car_for_engine = {}
    for script in sorted(engine_voice_folder.glob("*__*.mr")):
        car_name, engine_name = script.stem.split("__", 1)
        first_car_for_engine.setdefault(engine_name, script)
        target = profiles_folder / f"es_{engine_name}__{car_name}.mr"
        if not target.exists():
            skipped.append(script.name)
        elif is_engine_voice_diesel(script):
            generated_diesels.append(target.name)
        else:
            write_script(script, target)
            written.append(target.name)
    for target in sorted(profiles_folder.glob("es_*.mr")):
        if "__" in target.stem:
            continue
        source = first_car_for_engine.get(target.stem[len("es_"):])
        if source is None:
            raise SystemExit(f"{target.name}: no EngineVoice engine of that name")
        if is_engine_voice_diesel(source):
            generated_diesels.append(target.name)
            continue
        write_script(source, target)
        written.append(target.name)
    named = {name for target in written for name in NAMED_RESPONSE.findall((profiles_folder / target).read_text())}
    for response in sorted(engine_voice_folder.glob("*.wav")):
        if response.name in named:
            shutil.copyfile(response, profiles_folder / response.name)
    manifest = profiles_folder / "engine_families.tsv"
    manifest.write_text(EXHAUST_OVERRIDE.sub("", manifest.read_text()))

    not_from_engine_voice = sorted({p.name for p in profiles_folder.glob("es_*.mr")} - set(written) - set(generated_diesels))
    if not_from_engine_voice:
        raise SystemExit(f"left as generated (no EngineVoice version): {', '.join(not_from_engine_voice)}")
    print(f"wrote {len(written)} petrol scripts into {profiles_folder}; {len(generated_diesels)} diesels stay as generated")
    if skipped:
        print(f"not in the mod's manifests, skipped: {', '.join(skipped)}")


if __name__ == "__main__":
    main()
