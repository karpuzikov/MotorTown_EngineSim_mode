"""Coasting must not fire the synthesizer's cylinders (in-game 'wall drill' sound)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++17 compiler')
class OverrunFuelCutTests(unittest.TestCase):
    def test_fuel_cut_hysteresis_and_engine_scaling(self):
        with tempfile.TemporaryDirectory(prefix='mtes-fuel-cut-') as temp:
            executable = Path(temp) / 'fuel-cut-test'
            build = subprocess.run([
                'g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'), str(ROOT / 'tests/overrun_fuel_cut_test.cpp'),
                '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_backend_uses_fuel_cut_instead_of_permanent_ignition(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        self.assertIn('#include "overrun_fuel_cut.h"', backend)
        self.assertIn('m_fuelCut.update(', backend)
        self.assertNotIn('getIgnitionModule()->m_enabled = true;', backend)


if __name__ == '__main__':
    unittest.main()
