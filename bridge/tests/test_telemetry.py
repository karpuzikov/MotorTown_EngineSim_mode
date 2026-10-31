import os
import ctypes.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LUA = os.environ.get('MTES_TEST_LUA') or shutil.which('lua') or shutil.which('texlua')


@unittest.skipUnless(LUA, 'Requires Lua 5.3+ or texlua')
class TelemetryTests(unittest.TestCase):
    lua = LUA
    def sample(self, scenario, report='diagnostics'):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, TMP=temp, TEMP=temp)
            result = subprocess.run([self.lua, str(ROOT / 'bridge/tests/telemetry_harness.lua'),
                                     str(ROOT / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua'), scenario],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            packet = (Path(temp) / 'MotorTownEngineSim_telemetry.txt').read_text().split()
            diagnostics = (Path(temp) / f'MotorTownEngineSim_{report}.txt').read_text()
            return packet, diagnostics

    def test_getters_follow_autopilot_with_zero_driver_input(self):
        packet, _ = self.sample('autopilot')
        self.assertEqual(packet[:4], ['MTES1', '4100.000', '0.8000', '1'])

    def test_nested_struct_data_is_read_from_its_own_layout(self):
        packet, _ = self.sample('struct')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_missing_component_is_rediscovered_after_initial_vehicle_detection(self):
        packet, _ = self.sample('late_component')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_explicit_ignition_off_is_preserved_despite_residual_rpm(self):
        packet, _ = self.sample('ignition_off')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '0'])

    def test_ignition_false_is_a_valid_candidate_during_discovery(self):
        packet, _ = self.sample('ignition_initially_off')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '0'])

    def test_reflection_failure_is_visible_in_diagnostics(self):
        packet, diagnostics = self.sample('reflection_error')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])
        self.assertIn('Synthetic reflection failure', diagnostics)

    def test_getter_failure_is_visible_in_diagnostics(self):
        packet, diagnostics = self.sample('getter_error')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])
        self.assertIn('Synthetic RPM getter failure', diagnostics)

    def test_late_actual_throttle_replaces_a_complete_driver_input_fallback(self):
        packet, _ = self.sample('late_actual_throttle')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_nested_structs_at_the_same_data_address_keep_distinct_layouts(self):
        packet, _ = self.sample('struct_alias')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])

    def test_reflection_work_is_bounded_during_metadata_enumeration(self):
        packet, _ = self.sample('metadata_budget')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])

    def test_failed_throttle_path_is_rediscovered(self):
        packet, _ = self.sample('changed_throttle_getter')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.7500', '1'])

    def test_truncated_getter_signature_is_never_invoked(self):
        packet, diagnostics = self.sample('truncated_getter')
        self.assertEqual(packet[:4], ['MTES1', '0.000', '0.0000', '0'])
        self.assertIn('metadata budget exhausted', diagnostics)

    def test_discovery_snapshot_records_a_component_that_appears_later(self):
        _, snapshot = self.sample('late_component', report='discovery')
        self.assertIn('v0.2.12', snapshot)
        self.assertIn('VehicleSimulation.GetEngineRPM() = 2400', snapshot)
        self.assertIn('RPM=VehicleSimulation.GetEngineRPM()', snapshot)

    def test_engine_component_precedes_unrelated_deep_seat_metadata(self):
        packet, snapshot = self.sample('deep_vehicle', report='discovery')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])
        self.assertIn('RPM=EngineComponent.GetEngineRPM()', snapshot)
        self.assertIn('Priority engine/gear/audio fields:', snapshot)

    def test_gear_changes_are_visible_without_changing_audio_packet_abi(self):
        packet, diagnostics = self.sample('gear_probe')
        self.assertEqual(packet[:4], ['MTES1', '2400.000', '0.6500', '1'])
        self.assertEqual(len(packet), 5)
        self.assertIn('gear=Transmission.CurrentGear', diagnostics)
        self.assertIn('Live gear: 3', diagnostics)
        self.assertIn('Live gear: 4', diagnostics)

    def test_snapshot_keeps_engine_audio_fields_visible_after_inventory_limit(self):
        _, snapshot = self.sample('audio_inventory', report='discovery')
        self.assertIn('Priority engine/gear/audio fields:', snapshot)
        self.assertIn('EngineSoundComponent', snapshot)


@unittest.skipUnless(shutil.which('g++') and ctypes.util.find_library('lua5.4'),
                     'Requires a C++ compiler and Lua5.4 shared library')
class NativeIterationTests(TelemetryTests):
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
        result = subprocess.run([self.lua, str(ROOT / 'bridge/tests/telemetry_harness.lua'),
                                 str(ROOT / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua'),
                                 'iterator_contract'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
