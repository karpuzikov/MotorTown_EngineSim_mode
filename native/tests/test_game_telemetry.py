"""Compile the real native telemetry parser and exercise stale/invalid packets."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class GameTelemetryTests(unittest.TestCase):
    def test_packet_validation_and_staleness(self):
        with tempfile.TemporaryDirectory(prefix='mtes-game-telemetry-') as directory:
            target = Path(directory) / 'telemetry-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/game_telemetry_test.cpp'),
                str(ROOT / 'src/game_telemetry.cpp'), '-o', str(target),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(target), str(Path(directory) / 'native.txt')],
                                 capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
