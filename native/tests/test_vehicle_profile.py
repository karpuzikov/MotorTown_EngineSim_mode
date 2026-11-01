"""Compile and exercise exact, sandboxed per-engine profile resolution."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires C++20 compiler')
class VehicleProfileTests(unittest.TestCase):
    def test_exact_engine_asset_matches_only_packaged_scripts(self):
        with tempfile.TemporaryDirectory(prefix='mtes-profiles-') as directory:
            executable = Path(directory) / 'vehicle-profile-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/vehicle_profile_test.cpp'),
                str(ROOT / 'src/vehicle_profile.cpp'),
                str(ROOT / 'src/game_telemetry.cpp'), '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            mod_root = Path(directory) / 'mod'
            mod_root.mkdir()
            run = subprocess.run([str(executable), str(mod_root)],
                                 capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


class PackagedFamilyRuleTests(unittest.TestCase):
    """Python's re matches these ECMAScript patterns identically."""

    def resolve(self, asset, cue='', max_rpm=0):
        import re
        rules = []
        for line in (ROOT / 'profiles/engine_families.tsv').read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            field, pattern, profile = line.split('\t')
            if field == 'maxrpm':
                low, high = (float(x) for x in pattern.split('-'))
                rules.append((field, (low, high), profile))
            else:
                rules.append((field, re.compile(pattern, re.IGNORECASE), profile))
        exact = {}
        for line in (ROOT / 'profiles/engine_profiles.tsv').read_text().splitlines():
            if line and not line.startswith('#'):
                key, profile = line.split('\t')
                exact[key] = profile
        if asset in exact:
            return exact[asset]
        for wanted, name in (('asset', asset), ('cue', cue)):
            for field, pattern, profile in rules:
                if field == wanted and name and pattern.search(name):
                    return None if profile == '-' else profile
        for field, (low, high), profile in (r for r in rules if r[0] == 'maxrpm'):
            if max_rpm > 0 and low <= max_rpm <= high:
                return None if profile == '-' else profile
        return 'STOCK'

    def test_every_rule_points_to_a_packaged_profile(self):
        for line in (ROOT / 'profiles/engine_families.tsv').read_text().splitlines():
            if line and not line.startswith('#'):
                field, _, profile = line.split('\t')
                self.assertIn(field, ('asset', 'cue', 'maxrpm'))
                if profile != '-':
                    self.assertTrue((ROOT / 'profiles' / Path(profile).name).is_file(), profile)

    def test_known_motor_town_engines_get_matching_cylinder_layouts(self):
        prefix = 'MHEngineDataAsset /Game/Cars/Parts/Engine/'
        cases = {
            'FordSmalBlock302_V8_5L_140HP': 'assets/es_gm_ls.mr',
            'V6Sport_DOHC_200HP': 'assets/es_v6_60.mr',
            '2JZ320HP': 'assets/es_toyota_2jz.mr',
            'RB26DET276HP': 'assets/es_toyota_2jz.mr',
            'S58': 'assets/es_bmw_m52.mr',
            'I4Sport_150HP': 'assets/es_honda_b18c.mr',
            'I6Sport_200HP': 'assets/es_bmw_m52.mr',
            'Hemi392_525HP': 'assets/es_chev_454.mr',
            '81bb': 'assets/es_chev_454.mr',
            'V10ACR': 'assets/es_lfa_v10.mr',
            'Ferrari_275_V12_400HP': 'assets/es_ferrari_412.mr',
            'Electric_200kW': None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve(prefix + name + '.' + name, max_rpm=6000), expected)
        mystery = prefix + 'Mystery.Mystery'
        truck_cue = 'SoundCue /Game/Cars/Parts/Engine/Sound/Truck/MidDuty_02/SC_MidDuty.SC_MidDuty'
        self.assertEqual(self.resolve(mystery, truck_cue), 'assets/es_bmw_m52.mr')
        two_stroke = 'SoundCue /Game/Cars/Parts/Engine/Sound/2Stroke/SC_2StrokeEngine_Chainsaw.SC_2StrokeEngine_Chainsaw'
        self.assertEqual(self.resolve(mystery, two_stroke), 'assets/es_honda_trx520.mr')
        i4_cue = 'SoundCue /Game/Cars/Parts/Engine/Sound/I4Sport/SC_I4SportEngine.SC_I4SportEngine'
        self.assertEqual(self.resolve(mystery, i4_cue), 'assets/es_honda_b18c.mr')
        # The default V8 cue says nothing about the engine: MaxRPM decides,
        # and every combustion engine gets a profile.
        v8_cue = 'SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine'
        self.assertEqual(self.resolve(mystery, v8_cue, 2500), 'assets/es_bmw_m52.mr')
        self.assertEqual(self.resolve(mystery, v8_cue, 4500), 'assets/es_chev_454.mr')
        self.assertEqual(self.resolve(mystery, v8_cue, 6000), 'assets/es_gm_ls.mr')
        self.assertEqual(self.resolve(mystery, v8_cue, 8000), 'assets/es_honda_b18c.mr')
        self.assertEqual(self.resolve(mystery, v8_cue, 12000), 'assets/es_hayabusa.mr')
        for rpm in range(1, 30001, 50):
            self.assertNotEqual(self.resolve(mystery, v8_cue, rpm), 'STOCK', rpm)
