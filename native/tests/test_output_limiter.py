"""Peaks that the 3D mix gain would push past full scale are bent, not clipped."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires C++20 compiler')
class OutputLimiterTests(unittest.TestCase):
    def test_limiter_never_lets_the_gained_pcm_pass_full_scale(self):
        with tempfile.TemporaryDirectory(prefix='mtes-limiter-') as directory:
            executable = Path(directory) / 'output-limiter-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/output_limiter_test.cpp'), '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_the_xaudio2_sink_limits_before_the_gain_is_applied(self):
        source = (ROOT / 'src/xaudio2_sink.cpp').read_text()
        self.assertIn('limit_peaks_for_gain(block->samples.data(), frames, m_impl->peakOutputGain);', source)


if __name__ == '__main__':
    unittest.main()
