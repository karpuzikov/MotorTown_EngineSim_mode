import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LUA = os.environ.get('MTES_TEST_LUA') or shutil.which('lua') or shutil.which('texlua')


@unittest.skipUnless(LUA, 'Requires Lua 5.3+ or texlua')
class TelemetryTests(unittest.TestCase):
    def sample(self, scenario, report='diagnostics'):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, TMP=temp, TEMP=temp)
            result = subprocess.run([LUA, str(ROOT / 'bridge/tests/telemetry_harness.lua'),
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
        self.assertIn('v0.2.9', snapshot)
        self.assertIn('VehicleSimulation.GetEngineRPM() = 2400', snapshot)
        self.assertIn('RPM=VehicleSimulation.GetEngineRPM()', snapshot)


if __name__ == '__main__':
    unittest.main()
