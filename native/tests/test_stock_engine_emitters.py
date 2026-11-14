"""Exercise the portable engine/exhaust gain owner against real C++ methods."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class StockEngineEmitterTests(unittest.TestCase):
    def test_multi_emitter_mute_is_atomic_and_reversible(self):
        with tempfile.TemporaryDirectory(prefix='mtes-engine-emitters-') as temp:
            executable = Path(temp) / 'stock-engine-emitters-test'
            result = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/stock_engine_emitters_test.cpp'),
                str(ROOT / 'src/stock_engine_emitters.cpp'),
                '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
