import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import generate_engine_scripts as generator  # noqa: E402

ENGINES, CARS = generator.load_specs()


def journal_angles(engine_id):
    engine = ENGINES[engine_id]
    fire = generator.firing_angles_deg(engine)
    banks_deg = generator.bank_angles_deg(engine)
    banks = generator.cylinders_by_bank(engine, fire, banks_deg)
    angles = {}
    for bank, bank_deg in zip(banks, banks_deg):
        for cylinder in bank:
            angles[cylinder] = generator.journal_angle_deg(fire[cylinder], bank_deg, banks_deg[0])
    return banks, angles


class FiringGeometryTest(unittest.TestCase):
    def test_small_block_chevy_odd_cylinders_share_a_bank_and_pins_pair_up(self):
        banks, angles = journal_angles("chevy_350_l48")
        self.assertEqual(banks, [[1, 3, 5, 7], [2, 4, 6, 8]])
        for left, right in ((1, 2), (3, 4), (5, 6), (7, 8)):
            self.assertAlmostEqual(angles[left], angles[right])

    def test_ford_windsor_numbers_one_to_four_on_one_bank(self):
        banks, angles = journal_angles("ford_302_windsor")
        self.assertIn([1, 2, 3, 4], banks)
        for a, b in ((1, 5), (2, 6), (3, 7), (4, 8)):
            self.assertAlmostEqual(angles[a], angles[b])

    def test_inline_four_is_a_flat_plane_crank(self):
        _, angles = journal_angles("chevy_153_i4")
        self.assertEqual([angles[c] for c in (1, 2, 3, 4)], [0.0, 180.0, 180.0, 0.0])

    def test_uneven_fire_intervals_are_kept(self):
        fire = generator.firing_angles_deg(ENGINES["honda_cb250_twin"])
        self.assertEqual(fire, {1: 0.0, 2: 180.0})


class ScriptGenerationTest(unittest.TestCase):
    def test_every_four_stroke_engine_produces_a_script(self):
        for engine in ENGINES.values():
            script, derived = generator.engine_script(engine, generator.first_car_using(engine["id"], CARS))
            self.assertIn("set_engine(motor_town_engine())", script)
            self.assertTrue(script.isascii(), engine["id"])
            self.assertTrue(script.rstrip().endswith("main()"), "the compiler only runs top-level statements")
            self.assertGreater(derived["chamber_volume"], 0.0)

    def test_compression_ratio_sets_clearance_volume(self):
        derived = generator.derive(ENGINES["chevy_350_l48"], generator.first_car_using("chevy_350_l48", CARS))
        swept = derived["displacement_litres"] / 8 / 1000.0
        self.assertAlmostEqual((swept + derived["chamber_volume"]) / derived["chamber_volume"], 10.25)

    def test_two_stroke_fires_and_opens_every_revolution(self):
        script, _ = generator.engine_script(ENGINES["detroit_8v71"], generator.first_car_using("detroit_8v71", CARS))
        self.assertIn("sparks_per_cycle: 2", script)
        self.assertIn("lobes_per_cycle: 2", script)
        self.assertEqual(generator.firing_angles_deg(ENGINES["detroit_8v71"])[7], 45.0)
        boost = generator.boost(ENGINES["vespa_150_2t"], generator.derive(
            ENGINES["vespa_150_2t"], generator.first_car_using("vespa_150_2t", CARS)))
        self.assertGreaterEqual(boost["full_load_pressure_ratio"], 1.25)


if __name__ == "__main__":
    unittest.main()
