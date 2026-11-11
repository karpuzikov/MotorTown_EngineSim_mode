import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import exhaust_response  # noqa: E402
import package_mod_profiles as packager  # noqa: E402


class PackageModProfilesTest(unittest.TestCase):
    def test_installed_horsepower_picks_the_nearest_rated_option(self):
        ranges = packager.horsepower_ranges([{"power_hp": 300}, {"power_hp": 140}, {"power_hp": 200}])
        self.assertEqual([(engine["power_hp"], hp) for engine, hp in ranges],
                         [(140, "0-170"), (200, "171-250"), (300, "251-100000")])

    def test_vehicle_keys_follow_blueprint_class_names(self):
        self.assertEqual(packager.vehicle_key("Trophy2"), "trophy")
        self.assertEqual(packager.vehicle_key("PoliceInterceptor1"), "policeinterceptor")
        self.assertEqual(packager.vehicle_key("FL1"), "fl1")
        self.assertEqual(packager.vehicle_key("Kuda_Dryvan_4x2"), "kudadryvan4x2")

    def test_every_packaged_profile_plays_the_exhaust_response_engine_voice_gave_it(self):
        # The profiles come from EngineVoice (sync_engine_voice_engines.py): petrol engines keep Engine
        # Simulator's road muffler (settings.ini "muffler" may brighten it), diesels the truck response the
        # owner picked by ear, the hand-made MC-9 its response fitted to the owner's recording.
        profiles = sorted(packager.PROFILES_DIR.glob("es_*.mr"))
        self.assertGreater(len(profiles), 100)
        for profile in profiles:
            text = profile.read_text()
            responses = set(re.findall(r"impulse_response:\s*(ir_lib\.\w+|\w+)", text))
            if profile.name == "es_detroit_6v92ta__1980_mci_mc_9.mr":
                self.assertEqual(responses, {"mc9_exhaust_response"}, profile.name)
            elif "lean_ignition_limit: 1000.0" in text:
                self.assertEqual(responses, {"truck_exhaust"}, profile.name)
            else:
                self.assertEqual(responses, {"ir_lib.default_0"}, profile.name)
        for response in ("smooth/smooth_39_treble_plus_8db.wav", "smooth/smooth_39_treble_plus_14db.wav"):
            self.assertTrue((packager.SOUND_LIBRARY_DIR / response).is_file(), response)

    def test_a_response_a_script_names_ships_next_to_it(self):
        # Engine Simulator resolves a response named in a script relative to the script's folder. With
        # truck_exhaust.wav in sound-library/ every diesel failed to load in game: silent (2026-11-11).
        for profile in sorted(packager.PROFILES_DIR.glob("es_*.mr")):
            for name in re.findall(r'impulse_response \w+\(filename: "([^"]+)"', profile.read_text()):
                self.assertTrue((profile.parent / name).is_file(), f"{profile.name}: {name}")

    def rules(self):
        rows = []
        for line in (packager.PROFILES_DIR / "engine_families.tsv").read_text().splitlines():
            if line and not line.startswith("#"):
                rows.append(line.split("\t"))
        return rows

    def test_every_rule_names_a_shipped_script_and_no_exhaust_override(self):
        # A rule naming a file that is not installed voids the whole manifest in game (the mod then keeps every
        # stock sound). No "#exhaust=": each script plays the response it names, as heard in EngineVoice.
        scripted = 0
        for field, pattern, script, *_ in self.rules():
            if script == "-":
                continue
            scripted += 1
            match = re.fullmatch(r"assets/(es_\w+)\.mr", script)
            self.assertTrue(match, f"{field} {pattern}: {script}")
            self.assertTrue((packager.PROFILES_DIR / f"{match.group(1)}.mr").is_file(), script)
        self.assertGreater(scripted, 200)

    def test_the_shipped_responses_are_those_the_specs_ask_for(self):
        # No stale or missing response after a spec change without repackaging.
        engines, cars = packager.generator.load_specs()
        wanted = set()
        for car in cars:
            if car.get("keep_stock"):
                continue
            exhaust = car["exhaust"]
            for engine_id in car["engines"]:
                displacement = packager.generator.derive(engines[engine_id], car)["displacement_litres"]
                corner, stages = exhaust_response.exhaust_response(
                    displacement, exhaust["pipe_mm"], len(exhaust["silencers"]))
                wanted.add(exhaust_response.response_name(corner, stages))
        shipped = {f"exhaust/{path.name}" for path in (packager.SOUND_LIBRARY_DIR / "exhaust").glob("*.wav")}
        self.assertEqual(shipped, wanted)

if __name__ == "__main__":
    unittest.main()


class HandmadeProfileTest(unittest.TestCase):
    def test_handmade_script_replaces_the_generated_one(self):
        name = "es_ford_flathead_239__1948_ford_f_1"
        # EngineVoice calibrates every petrol engine's idle throttle; nothing else of the hand-made file changes.
        without_idle = lambda text: re.sub(r"idle_throttle_plate_position: [0-9.]+", "", text)
        packaged = (packager.PROFILES_DIR / f"{name}.mr").read_text()
        self.assertEqual(without_idle(packaged), without_idle((packager.HANDMADE_DIR / f"{name}.mr").read_text()))
