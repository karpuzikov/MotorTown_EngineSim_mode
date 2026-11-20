"""Check native Windows audio output's portable contract and build inclusion."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("g++"), "Requires a C++20 compiler")
class XAudio2SinkTests(unittest.TestCase):
    def test_portable_sink_contract(self):
        with tempfile.TemporaryDirectory(prefix="mtes-xaudio2-") as directory:
            target = Path(directory) / "sink-test"
            build = subprocess.run(
                ["g++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                 "-I", str(ROOT / "src"), str(ROOT / "tests/xaudio2_sink_portability_test.cpp"),
                 str(ROOT / "src/xaudio2_sink.cpp"),
                 str(ROOT / "src/pcm_block_pool.cpp"), "-o", str(target)],
                capture_output=True, text=True,
            )
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(target)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_shipping_module_links_the_windows_audio_library(self):
        cmake = (ROOT / "CMakeLists.txt").read_text()
        self.assertIn("src/pcm_block_pool.cpp", cmake)
        self.assertIn("src/xaudio2_sink.cpp", cmake)
        self.assertIn("xaudio2", cmake)
