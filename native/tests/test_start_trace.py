"""The game's engine state around each start is logged in a bounded window."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class StartTraceTests(unittest.TestCase):
    def test_windows_open_on_vehicle_ignition_and_rest_and_are_bounded(self):
        with tempfile.TemporaryDirectory(prefix='mtes-start-trace-') as temp:
            executable = Path(temp) / 'start-trace-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'), str(ROOT / 'tests/start_trace_test.cpp'),
                '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_the_mod_logs_the_game_state_it_is_given_to_start_with(self):
        mod = (ROOT / 'src/dllmain.cpp').read_text()
        self.assertIn('#include "start_trace.h"', mod)
        self.assertIn('m_startTrace.update(', mod)
        self.assertIn('[MTES] Start trace +{} s:', mod)
        # The line carries what decides how a start is played.
        for field in ('sample->state.rpm', 'sample->state.throttle', 'sample->state.ignition'):
            self.assertIn(field, mod)


if __name__ == '__main__':
    unittest.main()
