import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
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


if __name__ == "__main__":
    unittest.main()


class HandmadeProfileTest(unittest.TestCase):
    def test_handmade_script_replaces_the_generated_one(self):
        name = "es_ford_flathead_239__1948_ford_f_1"
        packaged = (packager.PROFILES_DIR / f"{name}.mr").read_text()
        self.assertEqual(packaged, (packager.HANDMADE_DIR / f"{name}.mr").read_text())

    def test_every_vehicle_gets_the_one_fleet_exhaust_response(self):
        self.assertEqual((packager.EXHAUST_DIR / "fleet.wav").read_bytes(),
                         packager.FLEET_EXHAUST_SOURCE.read_bytes())
        rules = [line.split("\t") for line in (packager.PROFILES_DIR / "engine_families.tsv").read_text().splitlines()
                 if line and not line.startswith("#")]
        scripted = [rule for rule in rules if rule[2] != "-"]
        self.assertGreater(len(scripted), 100)
        self.assertEqual([rule for rule in scripted if not rule[2].endswith(packager.FLEET_EXHAUST_SUFFIX)], [])
