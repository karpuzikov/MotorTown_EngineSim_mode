"""Traffic engines: stable voice assignment; DLL and Lua wiring."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TrafficEngineVoicesTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
    def test_voice_assignment(self):
        with tempfile.TemporaryDirectory(prefix='mtes-traffic-') as temp:
            executable = Path(temp) / 'traffic-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/traffic_voice_assignment_test.cpp'), '-o', str(executable)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_a_vehicle_missing_from_one_list_keeps_its_voice(self):
        voices = (ROOT / 'src/traffic_engine_voices.cpp').read_text()
        self.assertIn('traffic_vehicle_gone(m_voices[v].lastListed, now)', voices)

    def test_dll_and_lua_share_the_traffic_file_and_voice_count(self):
        dllmain = (ROOT / 'src/dllmain.cpp').read_text()
        self.assertIn('MotorTownEngineSim_traffic_telemetry.txt', dllmain)
        self.assertIn('m_traffic.start()', dllmain)
        lua = (ROOT.parent / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua').read_text()
        self.assertIn('MotorTownEngineSim_traffic_telemetry.txt', lua)
        header = (ROOT / 'src/traffic_engine_voices.h').read_text()
        self.assertIn('MaxVoices = 2', header)
        self.assertIn('TRAFFIC_VOICE_LIMIT = 2', lua)


if __name__ == '__main__':
    unittest.main()
