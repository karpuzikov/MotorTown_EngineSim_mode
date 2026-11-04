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

    def test_silenced_exhaust_uses_the_mild_response_not_the_open_pipe_one(self):
        # minimal_muffling_01 (open pipes) put 4 kHz at -6 dB re the loudest band
        # on every engine (Engine Simulator's own: -36 dB): hiss, not an engine.
        for car in CARS:
            if not car.get("exhaust") or not car["exhaust"]["silencers"]:
                continue  # electric: keeps the stock sound
            script, _ = generator.engine_script(ENGINES[car["engines"][0]], car)
            self.assertIn("impulse_response: ir_lib.mild_exhaust_0_reverb", script, car["real_car"])
            self.assertNotIn("minimal_muffling", script, car["real_car"])

    def test_diesels_are_throttled_not_fuel_metered(self):
        # Metering fuel leaned the charge past Engine Simulator's flame limit:
        # every diesel flared and stalled ~1.6 times a second (the pulsing).
        diesels = [engine for engine in ENGINES.values() if engine["fuel"] in ("diesel", "multifuel")]
        self.assertTrue(diesels)
        for engine in diesels:
            script, _ = generator.engine_script(engine, generator.first_car_using(engine["id"], CARS))
            self.assertNotIn("fuel-load-control", script, engine["id"])

    def test_a_car_without_silencer_data_fails_loudly(self):
        car = dict(CARS[0], exhaust=dict(CARS[0]["exhaust"], silencers=[]))
        with self.assertRaises(ValueError):
            generator.engine_script(ENGINES[car["engines"][0]], car)

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


class ClosedThrottleTest(unittest.TestCase):
    def test_choked_leak_passes_more_than_its_rating(self):
        # Choked at idle vacuum vs the 1.5 inHg rating point (gamma 1.4).
        self.assertAlmostEqual(generator.choked_to_carb_rating_flow_ratio(), 2.225, places=2)

    def test_closed_plate_leak_feeds_idle_at_idle_vacuum(self):
        # Regression: a fixed 0.995 plate on the 6x throttle idled at 0.6-0.93 atm.
        engine = ENGINES["chevy_350_l48"]
        displacement_ci = 350.0
        wide_open = generator.throttle_cfm(engine, displacement_ci)
        position = generator.closed_throttle_plate_position(engine, displacement_ci, wide_open)
        leak_cfm = wide_open * generator.math.cos(position * generator.math.pi / 2)
        idle_rpm = min(max(0.25 * engine["redline_rpm"], 600.0), 900.0)
        idle_scfm = displacement_ci / 1728.0 * idle_rpm / 2 * generator.IDLE_MANIFOLD_PRESSURE_ATM
        self.assertAlmostEqual(leak_cfm * generator.choked_to_carb_rating_flow_ratio(), idle_scfm, places=3)
        self.assertGreater(position, 0.995)



class ExhaustRunnerTest(unittest.TestCase):
    def test_runner_volume_includes_the_primary_pipe(self):
        # Regression: the port alone (~40 cc) chattered and popped at idle.
        engine = ENGINES["ford_flathead_239"]
        car = next(c for c in CARS if c["real_car"] == "1948 Ford F-1")
        derived = generator.derive(engine, car)
        volume = generator.exhaust_runner_volume_m3(derived)
        self.assertAlmostEqual(volume, derived["exhaust_runner_area"] * (derived["port_length"] + derived["primary_tube_length"]))
        self.assertGreater(volume, 5 * derived["exhaust_runner_area"] * derived["port_length"])
