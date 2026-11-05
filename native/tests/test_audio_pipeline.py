"""Exercise real MTES2 parsing through native synthesis and audio ownership."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires C++20 compiler')
class AudioPipelineTests(unittest.TestCase):
    def test_live_packets_drive_synthesis_once_and_fail_open(self):
        with tempfile.TemporaryDirectory(prefix='mtes-pipeline-') as directory:
            executable = Path(directory) / 'audio-pipeline-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/audio_pipeline_test.cpp'),
                str(ROOT / 'src/audio_pipeline.cpp'),
                str(ROOT / 'src/game_telemetry.cpp'),
                str(ROOT / 'src/game_audio.cpp'),
                str(ROOT / 'src/engine_audio.cpp'), '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
