import math
import re
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import exhaust_response as exhaust  # noqa: E402
import generate_engine_scripts as generator  # noqa: E402


def gain_at(samples, hz):
    """The response's gain at hz as Engine Simulator plays it (volume * s / 32767)."""
    scale = exhaust.BACKEND_VOLUME / exhaust.FULL_SCALE
    return exhaust._magnitude([s * scale for s in samples], hz)


class ExhaustFromHardwareTest(unittest.TestCase):
    def test_the_measured_truck_exhaust_is_the_anchor(self):
        # 12.74 L, 127 mm, one silencer: the Scania DC13 whose idle matched the
        # Hyundai Mighty recording (2026-11-05) with a 450 Hz stage.
        self.assertEqual(exhaust.exhaust_response(12.74, 127, 1), (450, 1))

    def test_a_smaller_engine_on_the_same_pipe_is_brighter(self):
        corners = [exhaust.exhaust_response(litres, 60, 1)[0] for litres in (12.0, 6.0, 3.0, 1.5, 0.7)]
        self.assertEqual(corners, sorted(corners))
        self.assertGreater(corners[-1], corners[0])

    def test_a_wider_pipe_is_brighter(self):
        corners = [exhaust.exhaust_response(5.0, pipe, 1)[0] for pipe in (32, 45, 57, 76, 102, 127)]
        self.assertEqual(corners, sorted(corners))
        self.assertGreater(corners[-1], corners[0])

    def test_each_silencer_is_a_stage_and_raises_the_stage_corner(self):
        # Silencers in series share the volume: n poles, each sqrt(n) higher.
        one = exhaust.exhaust_response(12.74, 127, 1)
        two = exhaust.exhaust_response(12.74, 127, 2)
        self.assertEqual((one[1], two[1]), (1, 2))
        self.assertGreater(two[0], one[0])
        self.assertAlmostEqual(two[0] / one[0], math.sqrt(2), delta=0.08)

    def test_the_scaling_is_only_trusted_an_octave_from_the_measurement(self):
        low, high = exhaust.CORNER_STEP_RANGE
        self.assertEqual(exhaust.step_corner_hz(0), 450)
        self.assertEqual(exhaust.step_corner_hz(high), 900)
        self.assertLess(exhaust.step_corner_hz(low), 450)
        # A 100 cc kart on a 25 mm can would be an open 1.5 kHz pipe unclamped.
        self.assertEqual(exhaust.exhaust_response(0.1, 25, 1)[0], 900)
        self.assertEqual(exhaust.exhaust_response(60.0, 25, 1)[0], exhaust.step_corner_hz(low))

    def test_corners_sit_on_a_quarter_octave_grid(self):
        corners = [exhaust.step_corner_hz(step) for step in range(*exhaust.CORNER_STEP_RANGE)]
        for lower, higher in zip(corners, corners[1:]):
            self.assertAlmostEqual(higher / lower, 2 ** 0.25, delta=0.01)

    def test_hardware_that_is_missing_is_an_error_not_a_default(self):
        for bad in ((0, 127, 1), (12.7, 0, 1), (12.7, 127, 0), (-1, 127, 1), (float("nan"), 127, 1)):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    exhaust.exhaust_response(*bad)

    def test_real_cars_land_where_their_hardware_puts_them(self):
        engines, cars = generator.load_specs()
        by_name = {car["real_car"]: car for car in cars}

        def response(car_name, engine_id):
            car = by_name[car_name]
            displacement = generator.derive(engines[engine_id], car)["displacement_litres"]
            return exhaust.exhaust_response(displacement, car["exhaust"]["pipe_mm"], len(car["exhaust"]["silencers"]))

        truck = response("Scania PRT 380", "scania_dc13")
        smaller_truck = response("Scania P-Series", "scania_dc9")
        kei_truck = response("1985 Subaru Sambar", "subaru_ek23")
        self.assertEqual(truck, (450, 1))
        self.assertGreater(smaller_truck[0], truck[0])  # same pipe, 9.3 L against 12.7 L
        self.assertEqual(kei_truck[0], exhaust.step_corner_hz(exhaust.CORNER_STEP_RANGE[1]))
        self.assertGreater(kei_truck[0], 1.5 * truck[0])  # a 0.66 L kei truck is not a truck


class BackendCalibrationTest(unittest.TestCase):
    def test_responses_are_calibrated_for_the_volume_the_backend_plays_them_at(self):
        backend = (Path(__file__).resolve().parents[2] / "native/src/engine_sim_backend.cpp").read_text()
        match = re.search(r"VehicleExhaustImpulseVolume = ([0-9.]+);", backend)
        self.assertTrue(match)
        self.assertEqual(float(match.group(1)), exhaust.BACKEND_VOLUME)


class ResponseImpulseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.responses = {(corner, stages): exhaust.impulse_response(corner, stages)
                         for corner, stages in ((318, 1), (450, 1), (900, 1), (636, 2), (900, 2))}

    def test_level_at_100_hz_is_the_calibrated_one(self):
        # The leveler and the loudness laws were tuned on the previous response.
        for key, samples in self.responses.items():
            with self.subTest(response=key):
                self.assertAlmostEqual(gain_at(samples, 100.0), exhaust.GAIN_AT_100_HZ, delta=0.0015)

    def test_the_chamber_corner_is_the_knee(self):
        # 3 dB down for the chamber's pole alone (a little less with the tail the
        # synthesizer trims); the exhaust's high pole, which is above the corner,
        # takes up to 3 dB more where the two come close.
        for corner in (318, 450, 900):
            samples = self.responses[(corner, 1)]
            with self.subTest(corner=corner):
                db = 20 * math.log10(gain_at(samples, corner) / gain_at(samples, 0.001))
                self.assertGreater(db, -6.0)
                self.assertLess(db, -2.5)

    def test_every_exhaust_has_the_same_high_frequency_asymptote(self):
        # (1 kHz / f)^2: -24 dB at 4 kHz of the pass band, whatever the corner.
        for corner in (318, 450, 900):
            samples = self.responses[(corner, 1)]
            with self.subTest(corner=corner):
                db = 20 * math.log10(gain_at(samples, 4000.0) / gain_at(samples, 0.001))
                self.assertAlmostEqual(db, -25.0, delta=2.0)

    def test_a_response_is_a_low_pass_that_falls_with_frequency(self):
        for key, samples in self.responses.items():
            with self.subTest(response=key):
                levels = [gain_at(samples, hz) for hz in (50, 100, 200, 400, 800, 1600, 3200)]
                self.assertEqual(levels, sorted(levels, reverse=True))

    def test_more_stages_fall_faster_above_the_corner(self):
        # Two 900 Hz stages against one: 6 dB per octave more, 12 in all.
        one = gain_at(self.responses[(900, 1)], 3600.0) / gain_at(self.responses[(900, 1)], 100.0)
        two = gain_at(self.responses[(900, 2)], 3600.0) / gain_at(self.responses[(900, 2)], 100.0)
        self.assertLess(two, 0.5 * one)

    def test_samples_fit_16_bits_and_end_above_the_synthesizers_trim(self):
        # Engine Simulator drops every sample at or under 100 after the last
        # one above it, and caps a response at 10000 samples.
        for key, samples in self.responses.items():
            with self.subTest(response=key):
                self.assertLessEqual(max(abs(s) for s in samples), exhaust.FULL_SCALE)
                self.assertGreater(abs(samples[-1]), exhaust.SYNTHESIZER_TRIM_THRESHOLD)
                self.assertLess(len(samples), 10000)
                self.assertGreater(len(samples), 20)

    def test_the_file_is_mono_pcm16_at_the_render_rate(self):
        with tempfile.TemporaryDirectory() as directory:
            name = exhaust.write_response(directory, 450, 1)
            self.assertEqual(name, "exhaust/lp1_450.wav")
            with wave.open(str(Path(directory) / name), "rb") as wav:
                self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()),
                                 (1, 2, 44100))
                self.assertEqual(wav.getnframes(), len(self.responses[(450, 1)]))


if __name__ == "__main__":
    unittest.main()
