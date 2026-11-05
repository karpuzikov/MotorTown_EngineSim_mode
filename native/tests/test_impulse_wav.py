"""Regression tests for the audio-only Engine Simulator impulse-response loader."""
import pathlib
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("g++"), "Requires C++20 compiler")
class ImpulseWavTests(unittest.TestCase):
    def test_pcm16_pcm24_malformed_and_incompatible_audio(self):
        with tempfile.TemporaryDirectory(prefix="mtes-wav-") as temp:
            exe = pathlib.Path(temp) / "impulse-wav-test"
            result = subprocess.run([
                "g++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "src"),
                str(ROOT / "tests/impulse_wav_test.cpp"),
                str(ROOT / "src/impulse_wav.cpp"), "-o", str(exe),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            args = [str(exe)]
            # Every exhaust response the rules name loads and survives the
            # synthesizer; a rule naming a file that fails voids the manifest.
            responses = sorted((ROOT / "profiles/sound-library/exhaust").glob("*.wav"))
            self.assertGreaterEqual(len(responses), 3)
            args += [f"packaged:{path}" for path in responses]
            source = os.environ.get("MTES_ENGINE_SIM_SOURCE")
            if source:
                for suffix in ("assets/sound-library/smooth/smooth_40.wav",
                               "assets/sound-library/archive/test_engine.wav"):
                    args.append(str(pathlib.Path(source) / suffix))
            run = subprocess.run(args, capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
