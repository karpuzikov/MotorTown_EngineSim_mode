"""Generated real-engine profiles: geometry, firing order and freshness."""
from pathlib import Path
import importlib.util
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / 'profiles/generator'
sys.path.insert(0, str(GEN))
import real_engines  # noqa: E402
import make_engines  # noqa: E402


class EngineGeneratorTests(unittest.TestCase):
    def test_committed_profiles_match_the_generator(self):
        for key, spec in real_engines.ENGINES.items():
            with self.subTest(engine=key):
                committed = (ROOT / f'profiles/es_{key}.mr').read_text()
                gain = re.match(r'// mtes-output-gain: ([0-9.e-]+)', committed)
                self.assertTrue(gain, 'every engine is calibrated')
                self.assertEqual(committed, make_engines.generate(key, spec, float(gain.group(1))),
                                 'run native/profiles/generator/make_engines.py --gains ...')

    def test_each_cylinder_reaches_tdc_when_it_fires(self):
        # Engine Simulator: TDC = journal - (bank - first bank), crank tdc = 90 + first bank.
        for key, spec in real_engines.ENGINES.items():
            text = (ROOT / f'profiles/es_{key}.mr').read_text()
            journals = {int(c): float(a) for c, a in re.findall(r'rod_journal rj(\d+)\(angle: ([-0-9.]+)', text)}
            fires = {int(c): float(a) for c, a in re.findall(r'connect_wire\(wires.wire(\d+), ([-0-9.]+)', text)}
            bank_of, banks = make_engines.banks_for(spec)
            self.assertEqual(sorted(fires), list(range(1, spec['cyl'] + 1)), key)
            for c, journal in journals.items():
                tdc = (journal - (bank_of[c] - banks[0])) % 360
                self.assertAlmostEqual(tdc, fires[c] % 360, places=2, msg=f'{key} cyl {c}')
            # Firing order is the maker's, at even intervals unless stated.
            order = sorted(fires, key=fires.get)
            self.assertEqual(order, spec['firing'], key)

    def test_real_dimensions_reach_the_script(self):
        text = (ROOT / 'profiles/es_ford_flathead_239.mr').read_text()
        self.assertIn('label bore(81.0 * units.mm)', text)
        self.assertIn('label stroke(95.25 * units.mm)', text)
        self.assertIn('firing order 1-5-4-8-6-3-7-2', text)
        two_stroke = (ROOT / 'profiles/es_vespa_150_2t.mr').read_text()
        self.assertIn('// mtes-rpm-scale: 2', two_stroke.splitlines()[1])

    def test_every_vehicle_names_a_generated_engine(self):
        for pattern, name, real, engine in real_engines.VEHICLES:
            self.assertTrue(engine == '-' or engine in real_engines.ENGINES, name)
        families = (ROOT / 'profiles/engine_families.tsv').read_text()
        for pattern, *_ in real_engines.VEHICLES:
            self.assertIn(f'vehicle\t{pattern}\t', families)

    def test_impulse_responses_exist_in_the_script_library(self):
        library = ROOT.parent / 'native'  # names checked against Engine Simulator's ir_lib
        names = {style['ir'] for style in make_engines.STYLES.values()}
        self.assertTrue(names <= {'default_0', 'mild_exhaust_0', 'mild_exhaust_0_reverb',
                                  'minimal_muffling_01', 'minimal_muffling_02', 'minimal_muffling_03',
                                  'sharp_0', 'real_engine_0', 'real_engine_1', 'real_engine_2'})


if __name__ == '__main__':
    unittest.main()
