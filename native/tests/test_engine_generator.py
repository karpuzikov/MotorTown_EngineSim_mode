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
                self.assertEqual(committed, make_engines.build(key, spec),
                                 'run native/profiles/generator/make_engines.py')

    def test_committed_exhausts_match_the_generator(self):
        import wave
        import make_exhausts
        for profile in make_exhausts.PROFILES:
            with self.subTest(exhaust=profile):
                with wave.open(str(ROOT / f'profiles/exhaust/{profile}.wav')) as committed:
                    self.assertEqual((committed.getnchannels(), committed.getframerate()), (1, 44100))
                    data = committed.readframes(committed.getnframes())
                expected = make_exhausts.impulse_response(profile)
                import numpy as np
                self.assertEqual(data, np.round(expected * 32767).astype('<i2').tobytes(),
                                 'run native/profiles/generator/make_exhausts.py')

    def test_exhausts_are_damped_like_real_ones_not_bare_pipes(self):
        # In game the undamped first version sounded like a pipe bolted to
        # the engine: 110-150 ms ringing. Recorded exhausts: 25-45 ms.
        import numpy as np
        import make_exhausts
        for profile, layout in make_exhausts.PROFILES.items():
            with self.subTest(exhaust=profile):
                energy = np.cumsum((make_exhausts.impulse_response(profile) ** 2)[::-1])[::-1]
                decay_20_db = np.argmax(energy / energy[0] < 0.01) / make_exhausts.FS
                self.assertLess(decay_20_db, 0.06)

    def test_the_dory_has_a_true_flathead_not_a_gm_ls(self):
        # In game the Dory buzzed: its engine was Engine Simulator's GM LS
        # model with only flathead bore and stroke.
        text = (ROOT / 'profiles/es_ford_flathead_239.mr').read_text()
        self.assertNotIn('07_gm_ls', text)
        self.assertIn('lift: 307 * units.thou', text)              # stock Ford cam
        self.assertIn('duration_at_50_thou: 197 * units.deg', text)
        self.assertIn('input lsa: 111.5 * units.deg', text)
        self.assertIn('intake_flow_rate: k_carb(160.0)', text)     # Holley 94 two-barrel
        self.assertIn('label rod_length(177.8 * units.mm)', text)
        self.assertEqual(text.count('exhaust_system exhaust'), 1)  # single exhaust
        order = re.findall(r'connect_wire\(wires.wire(\d)', text)
        self.assertEqual(order, ['1', '5', '4', '8', '6', '3', '7', '2'])

    def test_the_cheetah_is_an_mc9_detroit_with_its_matched_exhaust(self):
        # In game the Cheetah was a muffled sports car (generic bus exhaust),
        # then hiss and buzz (curves fitted to a video miked at the blower).
        # Its exhaust curve is now fitted to a real MC-9 idling.
        rules = (ROOT / 'profiles/engine_families.tsv').read_text()
        self.assertIn('vehicle\t^cheetah\tassets/es_detroit_6v92.mr'
                      '#exhaust=mtes-exhaust/bus_detroit.wav#loudness=86\n', rules)
        self.assertTrue((ROOT / 'profiles/exhaust/bus_detroit.wav').is_file())

    def test_two_strokes_vary_each_firing(self):
        # At twice the RPM, turbulence saturated and Engine Simulator burned
        # every firing identically: a buzz (real 6V92 idle varies 10-22%).
        for key in ('detroit_6v92', 'detroit_8v71', 'detroit_8v92'):
            text = (ROOT / f'profiles/es_{key}.mr').read_text()
            self.assertIn('// mtes-rpm-scale: 2', text)
            self.assertIn('burning_efficiency_randomness: 1.0, max_turbulence_effect: 100.0', text)

    def test_each_cylinder_reaches_tdc_when_it_fires(self):
        # Engine Simulator: TDC = journal - (bank - first bank), crank tdc = 90 + first bank.
        for key, spec in real_engines.ENGINES.items():
            if make_engines.template_for(key, spec):
                continue  # Engine Simulator's own tuned crank/firing
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
        text = (ROOT / 'profiles/es_chevy_350.mr').read_text()
        self.assertIn('label bore(101.6 * units.mm)', text)
        self.assertIn('label stroke(88.4 * units.mm)', text)
        self.assertIn('redline: 5800 * units.rpm', text)
        self.assertIn("Engine Simulator's 07_gm_ls.mr model", text)
        self.assertTrue(text.rstrip().endswith('main()'))
        for key in ('bmw_n55', 'chrysler_440'):  # engine-only templates get a main
            self.assertIn('public node main', (ROOT / f'profiles/es_{key}.mr').read_text())
        two_stroke = (ROOT / 'profiles/es_vespa_150_2t.mr').read_text()
        self.assertIn('// mtes-rpm-scale: 2', two_stroke.splitlines()[0])

    def test_every_vehicle_names_a_generated_engine(self):
        for pattern, name, real, engine in real_engines.VEHICLES:
            if isinstance(engine, tuple):
                family, engines = engine
                self.assertEqual(len(engines), len(real_engines.ENGINE_FAMILIES[family]), name)
                for key in engines:
                    self.assertIn(key, real_engines.ENGINES, name)
            else:
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
