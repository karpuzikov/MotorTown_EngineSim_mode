import re
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

    def test_every_packaged_profile_uses_the_road_vehicle_exhaust_response(self):
        # One response for all cars, hand-made scripts included: the Dory's own
        # (real_engine_1) left 4 kHz only 4 dB under its loudest band where the
        # same engine on this response sits 23 dB under, so the muffling differed.
        profiles = sorted(packager.PROFILES_DIR.glob("es_*.mr"))
        self.assertGreater(len(profiles), 100)
        for profile in profiles:
            responses = re.findall(r"impulse_response:\s*(ir_lib\.\w+)", profile.read_text())
            self.assertTrue(responses, profile.name)
            self.assertEqual(set(responses), {"ir_lib.default_0"}, profile.name)


if __name__ == "__main__":
    unittest.main()


class HandmadeProfileTest(unittest.TestCase):
    def test_handmade_script_replaces_the_generated_one(self):
        name = "es_ford_flathead_239__1948_ford_f_1"
        packaged = (packager.PROFILES_DIR / f"{name}.mr").read_text()
        self.assertEqual(packaged, (packager.HANDMADE_DIR / f"{name}.mr").read_text())
