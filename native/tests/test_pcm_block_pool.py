"""Exercise real fixed-size PCM storage without requiring an audio device."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("g++"), "Requires a C++20 compiler")
class PcmBlockPoolTests(unittest.TestCase):
    def test_pool_preserves_buffer_ownership_through_release(self):
        with tempfile.TemporaryDirectory(prefix="mtes-pcm-pool-") as directory:
            target = Path(directory) / "pool-test"
            build = subprocess.run(
                ["g++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                 "-I", str(ROOT / "src"), str(ROOT / "tests/pcm_block_pool_test.cpp"),
                 str(ROOT / "src/pcm_block_pool.cpp"), "-o", str(target)],
                capture_output=True, text=True,
            )
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(target)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
