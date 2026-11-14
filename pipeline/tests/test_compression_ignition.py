import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compression_ignition  # noqa: E402
import generate_engine_scripts as generator  # noqa: E402

PROFILES = Path(__file__).resolve().parents[2] / "native" / "profiles"
ENGINES, _ = generator.load_specs()


class CompressionIgnitionTest(unittest.TestCase):
    def test_every_diesel_profile_is_pump_governed_with_engine_simulators_oxygen_ratio(self):
        diesels = [p for p in PROFILES.glob("es_*.mr") if "lean_ignition_limit" in p.read_text()]
        self.assertTrue(diesels)
        for profile in diesels:
            script = profile.read_text()
            self.assertIn("diesel_injection_pump ignition_module(", script, profile.name)
            self.assertNotIn("molecular_afr: 17.75", script, profile.name)

    def test_conversion_keeps_heat_per_mole_of_oxygen(self):
        script = 'engine(redline: 2000 * units.rpm, fuel: fuel(molecular_mass: 170 * units.g, molecular_afr: 17.75, lean_ignition_limit: 1000.0))\n' \
                 'ignition_module ignition_module(timing_curve: timing_curve, rev_limit: 2400 * units.rpm, sparks_per_cycle: 1)\n'
        converted = compression_ignition.convert_script(script, ENGINES["detroit_6v92ta"])
        self.assertIn("molecular_mass: 119.7 * units.g", converted)
        self.assertIn("molecular_afr: 12.5", converted)
        self.assertEqual(converted, compression_ignition.convert_script(converted, ENGINES["detroit_6v92ta"]))


if __name__ == "__main__":
    unittest.main()
