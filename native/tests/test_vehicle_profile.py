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

    def rules(self):
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
        return rules

    @staticmethod
    def key(vehicle):
        name = vehicle.split(' ')[0]
        if name.endswith('_C'):
            name = name[:-2]
        return name.replace('_', '').lower()

    def resolve(self, vehicle, asset='', cue='', max_rpm=0):
        rules = self.rules()
        for wanted, name in (('vehicle', self.key(vehicle)), ('asset', asset), ('cue', cue)):
            for field, pattern, profile in rules:
                if field == wanted and name and pattern.search(name):
                    return None if profile == '-' else profile
        for field, (low, high), profile in (r for r in rules if r[0] == 'maxrpm'):
            if max_rpm > 0 and low <= max_rpm <= high:
                return None if profile == '-' else profile
        return 'STOCK'

    def test_every_rule_points_to_a_packaged_profile(self):
        for field, _, profile in self.rules():
            self.assertIn(field, ('vehicle', 'asset', 'cue', 'maxrpm'))
            if profile != '-':
                self.assertTrue((ROOT / 'profiles' / Path(profile).name).is_file(), profile)

    def test_each_car_gets_its_real_counterparts_engine(self):
        cases = {
            # In-game blueprint class (seen in UE4SS.log) -> real engine
            'DoryWrecker_C /Game/Maps/Jeju': 'assets/es_ford_flathead_239.mr',  # 1948 Ford F-1
            'Tuscan_C /Game/Maps/Jeju': 'assets/es_chevy_350.mr',               # 1969 Nova SS
            'Micky_C /Game/Maps/Jeju': 'assets/es_nissan_cg13.mr',              # Nissan Micra
            'Scooty_C /Game/Maps/Jeju': 'assets/es_vespa_150_2t.mr',            # Vespa
            'Elisa2_C /Game/Maps/Jeju': 'assets/es_ford_46_modular.mr',         # Crown Victoria
            'Trophy_Taxi_C /Game/Maps/Jeju': 'assets/es_vaz_2103.mr',           # Lada 2107
            'PoliceInterceptor_C /x': 'assets/es_chrysler_440.mr',
            'Police_C /x': 'assets/es_chrysler_hemi_57.mr',
            'ElisaPolice_C /x': 'assets/es_ford_46_modular.mr',
            'Fortem_C /x': 'assets/es_porsche_32_flat6.mr',
            'Raton_C /x': 'assets/es_lambo_l539.mr',
            'Pulse_C /x': None,                                                # Honda e
        }
        for vehicle, expected in cases.items():
            with self.subTest(vehicle=vehicle):
                self.assertEqual(self.resolve(vehicle, max_rpm=6000), expected)

    def test_unknown_cars_still_get_a_combustion_engine(self):
        prefix = 'MHEngineDataAsset /Game/Cars/Parts/Engine/'
        unknown = 'NewCar_C /x'
        cases = {
            'FordSmalBlock302_V8_5L_140HP': 'assets/es_ford_302_windsor.mr',
            'V6Sport_DOHC_200HP': 'assets/es_buick_38_turbo.mr',
            'I4_90HP': 'assets/es_nissan_cg13.mr',
            'I4Sport_150HP': 'assets/es_mazda_b6.mr',
            'Bike_i4_160HP': 'assets/es_bike_i4_1000.mr',
            'Bike_50HP': 'assets/es_triumph_650_twin.mr',
            'Kart_20HP': 'assets/es_kart_100_2t.mr',
            'Scooter_15HP': 'assets/es_vespa_150_2t.mr',
            'HeavyDuty_440HP': 'assets/es_cummins_isx15.mr',
            'MediumDuty_250HP': 'assets/es_navistar_dt466.mr',
            'Bus_300HP': 'assets/es_cummins_isb67.mr',
            'Ferrari_275_V12_400HP': 'assets/es_lambo_l539.mr',
            'Electric_300HP': None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve(unknown, prefix + name + '.' + name, max_rpm=6000), expected)
        for rpm in range(1, 40001, 50):
            self.assertNotEqual(self.resolve(unknown, prefix + 'Mystery.Mystery', '', rpm), 'STOCK', rpm)
