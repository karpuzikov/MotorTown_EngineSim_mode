"""The free-running engine's pedal follows the game's rpm (no dynamometer hold)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++17 compiler')
class CrankSpeedFollowerTests(unittest.TestCase):
    def test_pedal_follows_target_on_toy_engines(self):
        with tempfile.TemporaryDirectory(prefix='mtes-crank-follower-') as temp:
            executable = Path(temp) / 'crank-follower-test'
            build = subprocess.run([
                'g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'), str(ROOT / 'tests/crank_speed_follower_test.cpp'),
                '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_backend_runs_engine_free_without_a_rigid_hold_or_sound_patches(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        self.assertIn('m_follower.update(', backend)
        # The dynamometer is no rigid hold: it brakes above the game's rpm and
        # motors only an engine that cannot keep up, the unfired crank of the
        # first key turn, or (for a quarter second) one that just joined a
        # running car and has not fired yet.
        self.assertIn('const bool driven = m_motoring || crankingUnfired;', backend)
        self.assertIn('const bool held = driven || m_secondsHeldAtGameRpm > 0.0;', backend)
        self.assertIn('m_simulator->m_dyno.m_hold = held;', backend)
        self.assertNotIn('m_dyno.m_hold = true', backend)
        for forbidden in ('use_real_spec_sound', 'FiringHarmonicCut',
                          'OverrunFuelCut', 'm_speedWander', 'spin_forward'):
            self.assertNotIn(forbidden, backend)


if __name__ == '__main__':
    unittest.main()
