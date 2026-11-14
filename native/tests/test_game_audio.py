"""Compile the native fail-open game audio ownership contract."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class GameAudioTests(unittest.TestCase):
    def test_game_sound_handoff_restores_only_stock_engine_emitters(self):
        with tempfile.TemporaryDirectory(prefix='mtes-game-audio-') as directory:
            executable = Path(directory) / 'game-audio-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/game_audio_test.cpp'),
                str(ROOT / 'src/game_audio.cpp'),
                str(ROOT / 'src/engine_audio.cpp'), '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
