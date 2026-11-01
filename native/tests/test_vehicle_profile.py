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

    def resolve(self, asset, cue=''):
        import re
        rules = []
        for line in (ROOT / 'profiles/engine_families.tsv').read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            field, pattern, profile = line.split('\t')
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
        return None

    def test_every_rule_points_to_a_packaged_profile(self):
        for line in (ROOT / 'profiles/engine_families.tsv').read_text().splitlines():
            if line and not line.startswith('#'):
                field, _, profile = line.split('\t')
                self.assertIn(field, ('asset', 'cue'))
                if profile != '-':
                    self.assertTrue((ROOT / 'profiles' / Path(profile).name).is_file(), profile)

    def test_known_motor_town_engines_get_matching_cylinder_layouts(self):
        prefix = 'MHEngineDataAsset /Game/Cars/Parts/Engine/'
        cases = {
            'FordSmalBlock302_V8_5L_140HP.FordSmalBlock302_V8_5L_140HP': 'assets/es_gm_ls.mr',
            'V6Sport_DOHC_200HP.V6Sport_DOHC_200HP': 'assets/es_v6_60.mr',
            '2JZ320HP.2JZ320HP': 'assets/es_toyota_2jz.mr',
            'I4_1600_110HP.I4_1600_110HP': 'assets/es_honda_b18c.mr',
            'Inline6_Diesel_400HP.Inline6_Diesel_400HP': 'assets/es_bmw_m52.mr',
            'V12_600HP.V12_600HP': 'assets/es_ferrari_412.mr',
            'Electric_200kW.Electric_200kW': None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve(prefix + name), expected)
        truck_cue = 'SoundCue /Game/Cars/Parts/Engine/Sound/Truck/MidDuty_02/SC_MidDuty.SC_MidDuty'
        self.assertEqual(self.resolve(prefix + 'Mystery.Mystery', truck_cue), 'assets/es_bmw_m52.mr')
        v8_cue = 'SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine'
        self.assertEqual(self.resolve(prefix + 'Mystery.Mystery', v8_cue), 'assets/es_gm_ls.mr')
