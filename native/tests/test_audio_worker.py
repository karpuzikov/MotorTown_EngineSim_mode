"""In-process audio worker must not depend on Unreal update callbacks."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires C++20 compiler')
class AudioWorkerTests(unittest.TestCase):
    def test_ue4ss_mod_wires_real_worker_to_continuous_pcm_pacing(self):
        # The native worker integration test exercises real PCM polling, but
        # this guard protects the production DLL's constructor wiring too.
        dll = (ROOT / 'src/dllmain.cpp').read_text()
        self.assertIn('NativeAudioPipeline::Pacing::WorkerClock', dll)

    def test_windows_audio_worker_initializes_com_on_its_own_thread(self):
        # Windows XAudio2Create requires COM initialization on the caller's
        # thread. The Unreal thread's COM state does not transfer to jthread.
        source = (ROOT / 'src/audio_worker.cpp').read_text()
        self.assertIn('CoInitializeEx(nullptr, COINIT_MULTITHREADED)', source)
        self.assertIn('CoUninitialize()', source)

    def test_start_reports_worker_initialization_and_failed_thread_can_retry(self):
        source = (ROOT / 'src/audio_worker.cpp').read_text()
        self.assertIn('std::promise<bool>', source)
        self.assertIn('ready.set_value(false)', source)
        self.assertIn('future.get()', source)
        self.assertIn('if (!m_alive.load())', source)

    def test_slow_synthesis_focus_loss_staleness_and_safe_join(self):
        with tempfile.TemporaryDirectory(prefix='mtes-audio-worker-') as folder:
            exe = Path(folder) / 'audio-worker-test'
            sources = [
                'audio_worker.cpp', 'audio_pipeline.cpp', 'game_telemetry.cpp',
                'game_audio.cpp', 'engine_audio.cpp',
            ]
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/audio_worker_test.cpp'),
                *(str(ROOT / 'src' / name) for name in sources),
                '-o', str(exe),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe), str(Path(folder) / 'telemetry.txt')],
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
