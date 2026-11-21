import os
import ctypes.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LUA = os.environ.get('MTES_TEST_LUA') or shutil.which('lua5.4') or shutil.which('lua') or shutil.which('texlua')
EXPORTER = ROOT / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua'


@unittest.skipUnless(LUA, 'Requires Lua 5.3+ or texlua')
class TelemetryTests(unittest.TestCase):
    lua = LUA

    def run_scenario(self, scenario):
        temp = tempfile.mkdtemp(prefix='MTES telemetry ')
        self.addCleanup(shutil.rmtree, temp, True)
        env = dict(os.environ, TMP=temp, TEMP=temp)
        result = subprocess.run([self.lua, str(ROOT / 'bridge/tests/telemetry_harness.lua'), str(EXPORTER), scenario],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return Path(temp)

    def read(self, folder, name):
        path = folder / f'MotorTownEngineSim_{name}.txt'
        return path.read_text() if path.exists() else ''

    def sample(self, scenario, report='diagnostics'):
        folder = self.run_scenario(scenario)
        return self.read(folder, 'telemetry').split(), self.read(folder, report)

    def test_reads_documented_motor_town_engine_state(self):
        packet, _ = self.sample('live')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_discovery_snapshot_names_the_live_fields(self):
        _, snapshot = self.sample('live', report='discovery')
        self.assertIn('v0.3.0', snapshot)
        self.assertIn('Mapping rpm = NetLC_EngineHotState.CurrentRPM (value 2400', snapshot)
        self.assertIn('Mapping throttle = Throttle (value 0.65', snapshot)
        self.assertIn('Mapping ignition = NetLC_EngineHotState.bIgnitionOn (value true', snapshot)

    def test_autopilot_values_come_from_vehicle_state(self):
        packet, _ = self.sample('autopilot')
        self.assertEqual(packet[:4], ['MTES1', '4100.000', '0.8000', '1'])

    def test_rpm_follows_the_game_every_sample(self):
        packet, _ = self.sample('rpm_follows')
        self.assertEqual(packet[:4], ['MTES1', '3100.000', '0.6500', '1'])

    def test_ignition_off_is_reported(self):
        packet, _ = self.sample('ignition_off')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])

    def test_ignition_off_wins_over_residual_rpm(self):
        packet, _ = self.sample('engine_stopping')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '0'])

    def test_renamed_fields_are_found_inside_struct_layouts(self):
        # Struct values have no ForEachProperty in UE4SS; the layout comes from GetStruct().
        packet, snapshot = self.sample('renamed_fields', report='discovery')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])
        self.assertIn('Mapping rpm = EngineState.EngineRPM', snapshot)
        self.assertIn('Mapping throttle = ThrottleInput', snapshot)
        self.assertIn('EngineState.MaxRPM (FloatProperty) = 7000', snapshot)
        self.assertNotIn('Net_PTOThrottle (value', snapshot)

    def test_on_foot_sends_engine_off(self):
        packet, diagnostics = self.sample('on_foot')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])
        self.assertIn('not driving a vehicle', diagnostics)

    def test_leaving_the_vehicle_stops_the_engine_sound(self):
        packet, _ = self.sample('leave_vehicle')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])

    def test_seated_player_uses_the_controllers_vehicle(self):
        packet, _ = self.sample('seated')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_switching_vehicles_remaps(self):
        packet, diagnostics = self.sample('vehicle_switch')
        self.assertEqual(packet[:4], ['MTES1', '3000.000', '0.6500', '1'])
        self.assertIn('Vehicle DoryWrecker_C', diagnostics)
        self.assertIn('Vehicle Jemusi_C', diagnostics)

    def test_nothing_is_sampled_during_game_boot(self):
        folder = self.run_scenario('startup_delay')
        self.assertFalse((folder / 'MotorTownEngineSim_telemetry.txt').exists())
        self.assertIn('sampling starts in 30 s', self.read(folder, 'diagnostics'))

    def test_falls_back_to_async_loop_when_game_thread_timer_is_unavailable(self):
        packet, diagnostics = self.sample('timer_fallback')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])
        self.assertIn('using LoopAsync', diagnostics)


@unittest.skipUnless(shutil.which('g++') and ctypes.util.find_library('lua5.4'),
                     'Requires a C++ compiler and Lua5.4 shared library')
class NativeIterationTests(TelemetryTests):
    """Re-runs every scenario through the real UE4SS iterator stack operations."""
    __unittest_skip__ = False

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='MTES native Lua ')
        cls.lua = str(Path(cls.temp.name) / 'ue4ss-lua-test')
        library = ctypes.util.find_library('lua5.4')
        result = subprocess.run(['g++', '-std=c++17', str(ROOT / 'bridge/tests/ue4ss_iteration_boundary.cpp'),
                                 '-Wl,-l:' + library, '-o', cls.lua], capture_output=True, text=True)
        if result.returncode:
            cls.temp.cleanup()
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_native_binding_reproduces_false_failure_and_accepts_nil_and_true(self):
        result = subprocess.run([self.lua, str(ROOT / 'bridge/tests/telemetry_harness.lua'), str(EXPORTER),
                                 'iterator_contract'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
