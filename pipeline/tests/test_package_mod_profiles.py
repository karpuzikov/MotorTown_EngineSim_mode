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

    def test_every_packaged_profile_has_the_same_library_response_as_its_fallback(self):
        # One pipeline for all cars, hand-made scripts included (the Dory's own
        # response left 4 kHz only 4 dB under its loudest band where the same
        # engine on the library's road-vehicle response sits 23 dB under, so the
        # muffling differed). The script keeps that response for anything that
        # plays it without a rule; in game each rule's own exhaust replaces it.
        profiles = sorted(packager.PROFILES_DIR.glob("es_*.mr"))
        self.assertGreater(len(profiles), 100)
        for profile in profiles:
            responses = re.findall(r"impulse_response:\s*(ir_lib\.\w+)", profile.read_text())
            self.assertTrue(responses, profile.name)
            self.assertEqual(set(responses), {"ir_lib.default_0"}, profile.name)

    def rules(self):
        rows = []
        for line in (packager.PROFILES_DIR / "engine_families.tsv").read_text().splitlines():
            if line and not line.startswith("#"):
                rows.append(line.split("\t"))
        return rows

    def test_every_rule_names_an_exhaust_response_that_ships(self):
        # A rule naming a file that is not installed voids the whole manifest in
        # game (the mod then keeps every stock sound), so none may.
        named = set()
        scripted = 0
        for field, pattern, script, *_ in self.rules():
            if script == "-":
                continue
            scripted += 1
            match = re.fullmatch(r"assets/(es_\w+)\.mr#exhaust=(exhaust/lp([1-3])_(\d+)\.wav)", script)
            self.assertTrue(match, f"{field} {pattern}: {script}")
            self.assertTrue((packager.PROFILES_DIR / f"{match.group(1)}.mr").is_file(), script)
            self.assertTrue((packager.SOUND_LIBRARY_DIR / match.group(2)).is_file(), script)
            named.add(match.group(2))
        self.assertGreater(scripted, 200)
        # A few filters of one family, not a sound per car (and not one for all).
        self.assertGreaterEqual(len(named), 4)
        self.assertLessEqual(len(named), 24)

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

    def test_a_rule_carries_its_own_cars_exhaust(self):
        # One rule from a 12.7-litre truck and one from a 0.66-litre kei truck.
        by_key = {}
        for field, pattern, script, *_ in self.rules():
            by_key.setdefault(pattern, script)
        truck = re.search(r"#exhaust=exhaust/lp(\d)_(\d+)\.wav", by_key["^atlas6x2semi"])
        kei = re.search(r"#exhaust=exhaust/lp(\d)_(\d+)\.wav", by_key["^bora"])
        self.assertEqual(truck.groups(), ("1", "450"))
        self.assertGreater(int(kei.group(2)), 1.5 * int(truck.group(2)))


if __name__ == "__main__":
    unittest.main()


class HandmadeProfileTest(unittest.TestCase):
    def test_handmade_script_replaces_the_generated_one(self):
        name = "es_ford_flathead_239__1948_ford_f_1"
        packaged = (packager.PROFILES_DIR / f"{name}.mr").read_text()
        self.assertEqual(packaged, (packager.HANDMADE_DIR / f"{name}.mr").read_text())
