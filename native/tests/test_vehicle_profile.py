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
            field, pattern, profile, *horsepower = line.split('\t')
            hp = tuple(int(x) for x in horsepower[0].split('-')) if horsepower else None
            if field == 'maxrpm':
                low, high = (float(x) for x in pattern.split('-'))
                rules.append((field, (low, high), profile, hp))
            else:
                rules.append((field, re.compile(pattern, re.IGNORECASE), profile, hp))
        return rules

    @staticmethod
    def key(vehicle):
        name = vehicle.split(' ')[0]
        if name.endswith('_C'):
            name = name[:-2]
        return name.replace('_', '').lower()

    def resolve(self, vehicle, asset='', cue='', max_rpm=0):
        import re
        rules = self.rules()
        found = re.findall(r'(\d{1,5})HP(?![A-Za-z0-9])', asset, re.IGNORECASE)
        horsepower = int(found[-1]) if found else None

        def first(wanted, name):
            for field, pattern, profile, hp in rules:
                if field == wanted and name and pattern.search(name) and (
                        hp is None or (horsepower is not None and hp[0] <= horsepower <= hp[1])):
                    return profile
            return None
        if first('asset', asset) == '-':
            return None  # electric motors first, in any vehicle
        for wanted, name in (('vehicle', self.key(vehicle)), ('asset', asset), ('cue', cue)):
            profile = first(wanted, name)
            if profile:
                return None if profile == '-' else profile
        for field, (low, high), profile, _ in (r for r in rules if r[0] == 'maxrpm'):
            if max_rpm > 0 and low <= max_rpm <= high:
                return None if profile == '-' else profile
        return 'STOCK'

    def test_every_rule_points_to_a_packaged_profile(self):
        for field, _, profile, _ in self.rules():
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
        stock = {  # each car's stock EngineData (engine catalog)
            'DoryWrecker_C': 'FordSmalBlock302_V8_5L_140HP', 'Tuscan_C': 'FordSmalBlock302_V8_5L_140HP',
            'Micky_C': 'I4_90HP', 'Scooty_C': 'Scooter_10HP', 'Elisa2_C': 'FordSmalBlock302_V8_5L_180HP',
            'Trophy_Taxi_C': 'I4_90HP', 'Fortem_C': 'FordSmalBlock302_V8_5L_240HP',
            'Police_C': 'FordSmalBlock302_V8_5L_240HP', 'Raton_C': 'Ferrari_275_V12_400HP',
            'Pulse_C': 'Electric_130HP'}
        for vehicle, expected in cases.items():
            with self.subTest(vehicle=vehicle):
                name = stock.get(vehicle.split(' ')[0], 'FordSmalBlock302_V8_5L_180HP')
                asset = f'MHEngineDataAsset /Game/Cars/Parts/Engine/{name}.{name}'
                self.assertEqual(self.resolve(vehicle, asset, max_rpm=6000), expected)

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
            'MediumDuty_190HP': 'assets/es_navistar_dt466.mr',
            'MediumDuty_250HP': 'assets/es_cummins_isb67.mr',
            'Bus_300HP': 'assets/es_cummins_isl9.mr',
            'Ferrari_275_V12_400HP': 'assets/es_lambo_l539.mr',
            'Electric_300HP': None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve(unknown, prefix + name + '.' + name, max_rpm=6000), expected)
        for rpm in range(1, 40001, 50):
            self.assertNotEqual(self.resolve(unknown, prefix + 'Mystery.Mystery', '', rpm), 'STOCK', rpm)

    def test_each_car_and_installed_engine_gets_the_real_engine_of_that_power(self):
        prefix = 'MHEngineDataAsset /Game/Cars/Parts/Engine/'
        def engine(name):
            return prefix + name + '.' + name
        # In game both had MediumDuty_330HP and sounded the same.
        self.assertEqual(self.resolve('Kira_Van_C /x', engine('MediumDuty_330HP')),
                         'assets/es_deutz_f10l413f.mr')
        self.assertEqual(self.resolve('Brutus_Wrecker_C /x', engine('MediumDuty_330HP')),
                         'assets/es_mercedes_om936.mr')
        self.assertEqual(self.resolve('Kira_Van_C /x', engine('MediumDuty_190HP')),
                         'assets/es_deutz_f6l912.mr')
        self.assertEqual(self.resolve('Stinger_C /x', engine('FordSmalBlock302_V8_5L_140HP')),
                         'assets/es_chevy_350.mr')
        self.assertEqual(self.resolve('Stinger_C /x', engine('FordSmalBlock302_V8_5L_320HP')),
                         'assets/es_chevy_396.mr')
        # Liliput has a combustion engine in game (silent while it kept stock).
        self.assertEqual(self.resolve('Liliput_C /x', engine('Bus_140HP')),
                         'assets/es_iveco_f1c.mr')
        # An electric motor keeps its stock sound in any vehicle.
        self.assertIsNone(self.resolve('Kira_Van_C /x', engine('Electric_300HP')))
        self.assertIsNone(self.resolve('EVan_C /x', engine('Electric_130HP')))
