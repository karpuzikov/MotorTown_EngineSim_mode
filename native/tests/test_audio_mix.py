"""Stock-matched loudness and 3D position for the native engine sound."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class AudioMixTests(unittest.TestCase):
    def test_pan_settings_and_profile_directives(self):
        with tempfile.TemporaryDirectory(prefix='mtes-mix-') as temp:
            executable = Path(temp) / 'audio-mix-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'src'), str(ROOT / 'tests/audio_mix_test.cpp'),
                '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_backend_spins_engines_forward_with_engine_sim_leveler(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        # In game every model ran backwards (dyno from rest): 30-atm intake,
        # inverted throttle, drill-like coasting. Direction follows the
        # script's starter speed sign; forward spin precedes simulation.
        self.assertIn('getStarterSpeed() < 0.0 ? 1.0 : -1.0', backend)
        self.assertLess(backend.index('spin_forward(m_engine, from);'),
                        backend.index('m_simulator->startFrame(seconds);'))
        self.assertIn('profile_rpm_scale(script)', backend)  # two-strokes
        # Loudness is Engine Simulator's own (as in its demo); no extra
        # compressor or per-profile gain pulls it down in game.
        self.assertIn('audio.levelerTarget = EngineSimLevelerTargetWithHeadroom;', backend)
        self.assertNotIn('leveler.p_maxLevel', backend)

    def test_every_packaged_profile_is_a_complete_engine(self):
        profiles = sorted((ROOT / 'profiles').glob('es_*.mr'))
        self.assertGreaterEqual(len(profiles), 60)
        for profile in profiles:
            with self.subTest(profile=profile.name):
                self.assertNotIn('mtes-output-gain', profile.read_text())
                self.assertIn('set_engine(', profile.read_text())

    def test_xaudio2_output_applies_the_stock_mix(self):
        sink = (ROOT / 'src/xaudio2_sink.cpp').read_text()
        self.assertIn('SetOutputMatrix', sink)
        self.assertIn('XAUDIO2_VOICE_USEFILTER', sink)
        self.assertIn('SetFilterParameters', sink)
        pipeline = (ROOT / 'src/audio_pipeline.cpp').read_text()
        self.assertLess(pipeline.index('m_output.set_mix('), pipeline.index('m_output.submit('))
        dllmain = (ROOT / 'src/dllmain.cpp').read_text()
        self.assertIn('load_mod_settings(module_root())', dllmain)


if __name__ == '__main__':
    unittest.main()
