"""Real C++ audio bridge contract with a fake renderer only at the engine boundary."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("g++"), "Requires C++20 compiler")
class EngineAudioTests(unittest.TestCase):
    def test_no_additional_backend_read_after_render_deadline(self):
        source = (ROOT / 'src/engine_audio.cpp').read_text()
        self.assertIn('if (std::chrono::steady_clock::now() >= deadline) break;', source)

    def test_vehicle_handoff_fail_open_and_pcm_freshness(self):
        with tempfile.TemporaryDirectory(prefix="mtes-native-audio-") as temp:
            exe = pathlib.Path(temp) / "headless-audio-test"
            build = subprocess.run([
                "g++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                "-I", str(ROOT / "src"),
                str(ROOT / "tests/headless_audio_test.cpp"),
                str(ROOT / "src/engine_audio.cpp"), "-o", str(exe),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
