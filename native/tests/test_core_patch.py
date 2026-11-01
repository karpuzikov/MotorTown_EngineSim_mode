"""Safely patch a build-only Engine Simulator checkout for repeated vehicle swaps."""
import os
from pathlib import Path
import hashlib
import re
import shutil
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
try:
    import patch_engine_sim_core as patcher
except ModuleNotFoundError:
    patcher = None


def previous_synthesizer_bytes(modern: str, capacity: int) -> str:
    # Reconstruct an exact audited historical output batch to test upgrades
    # without depending on any player's configured Windows checkout.
    assert modern.count(patcher.STREAMED_BATCH) == 1
    monolithic = modern.replace(patcher.STREAMED_BATCH, patcher.MONOLITHIC_BATCH, 1)
    return monolithic.replace('16384', str(capacity))


@unittest.skipUnless(os.environ.get("MTES_ENGINE_SIM_SOURCE"),
                     "Set MTES_ENGINE_SIM_SOURCE to the pinned Engine Simulator checkout")
class CorePatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mtes-headless-core-")
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        for name in ("simulator.cpp", "piston_engine_simulator.cpp", "engine.cpp",
                     "synthesizer.cpp", "jitter_filter.cpp"):
            shutil.copyfile(Path(os.environ["MTES_ENGINE_SIM_SOURCE"]) / "src" / name,
                            self.root / "src" / name)
        (self.root / "scripting/src").mkdir(parents=True)
        shutil.copyfile(Path(os.environ["MTES_ENGINE_SIM_SOURCE"]) / "scripting/src/compiler.cpp",
                        self.root / "scripting/src/compiler.cpp")
        (self.root / "dependencies/submodules/piranha/src").mkdir(parents=True)
        shutil.copyfile(Path(os.environ["MTES_ENGINE_SIM_SOURCE"]) /
                        "dependencies/submodules/piranha/src/path.cpp",
                        self.root / "dependencies/submodules/piranha/src/path.cpp")

    def tearDown(self):
        self.temp.cleanup()

    def test_cleanup_is_complete_and_repeatable(self):
        self.assertIsNotNone(patcher)
        patcher.patch(self.root)
        simulator = (self.root / "src/simulator.cpp").read_text()
        piston = (self.root / "src/piston_engine_simulator.cpp").read_text()
        engine = (self.root / "src/engine.cpp").read_text()
        synth = (self.root / "src/synthesizer.cpp").read_text()
        jitter = (self.root / "src/jitter_filter.cpp").read_text()
        compiler = (self.root / "scripting/src/compiler.cpp").read_text()
        piranha_path = (self.root / "dependencies/submodules/piranha/src/path.cpp").read_text()
        self.assertIn("delete[] m_dynoTorqueSamples;", simulator)
        self.assertIn("m_dynoTorqueSamples = nullptr;", simulator)
        self.assertIn("delete[] m_crankshaftLinks;", piston)
        self.assertIn("m_crankshaftLinks = nullptr;", piston)
        self.assertIn("Simulator::destroy();", piston)
        self.assertNotIn("static double lastValveLift[8]", piston)
        self.assertNotIn("lastValveLift[i]", piston)
        self.assertIn("delete[] min_s;", engine)
        self.assertIn("delete[] max_s;", engine)
        self.assertIn("delete[] m_inputChannels[i].transferBuffer;", synth)
        self.assertIn("std::lock_guard<std::mutex> lock(m_lock0);", synth)
        self.assertNotIn("std::unique_lock<std::mutex> lk(m_inputLock);", synth)
        self.assertIn("std::array<int16_t, 1024> rendered", synth)
        self.assertIn("delete[] m_history;", jitter)
        self.assertNotIn("assert(m_antialiasingFilters == nullptr);", piston)
        self.assertIn("m_compiler->addSearchPath(scriptLibrary.toString());", compiler)
        self.assertIn('std::getenv("MTES_SCRIPT_LOG_PATH")', compiler)
        self.assertIn("return m_path->is_absolute();", piranha_path)
        self.assertNotIn("m_path->is_complete()", piranha_path)
        patcher.patch(self.root)
        self.assertEqual((self.root / "src/simulator.cpp").read_text(), simulator)
        self.assertEqual((self.root / "src/piston_engine_simulator.cpp").read_text(), piston)
        self.assertEqual((self.root / "src/engine.cpp").read_text(), engine)
        self.assertEqual((self.root / "src/synthesizer.cpp").read_text(), synth)
        self.assertEqual((self.root / "src/jitter_filter.cpp").read_text(), jitter)
        self.assertEqual((self.root / "scripting/src/compiler.cpp").read_text(), compiler)
        self.assertEqual((self.root / "dependencies/submodules/piranha/src/path.cpp").read_text(),
                         piranha_path)

    def test_unrecognized_source_is_rejected_without_modification(self):
        self.assertIsNotNone(patcher)
        bad = self.root / "src/piston_engine_simulator.cpp"
        bad.write_text("unexpected vendor source")
        sim = self.root / "src/simulator.cpp"
        original_sim = sim.read_bytes()
        with self.assertRaises(ValueError):
            patcher.patch(self.root)
        self.assertEqual(sim.read_bytes(), original_sim)
        self.assertEqual(bad.read_text(), "unexpected vendor source")

    def test_tampered_patched_file_is_rejected(self):
        patcher.patch(self.root)
        bad = self.root / "src/simulator.cpp"
        bad.write_text(bad.read_text().replace("delete[] m_dynoTorqueSamples;", "// allocation leaked;"))
        with self.assertRaises(ValueError):
            patcher.patch(self.root)

    def test_known_legacy_audio_limit_upgrades_existing_build_tree(self):
        patcher.patch(self.root)
        sound = self.root / 'src/synthesizer.cpp'
        modern = sound.read_text()
        old = previous_synthesizer_bytes(modern, 2000)
        self.assertEqual(hashlib.sha256(old.encode()).hexdigest(),
                         patcher.LEGACY_SYNTHESIZER_PATCHED_SHA)
        sound.write_text(old)
        patcher.patch(self.root)
        self.assertEqual(sound.read_text(), modern)
        patcher.patch(self.root)  # Upgrade is idempotent.

    def test_current_4096_audio_patch_upgrades_existing_windows_build(self):
        patcher.patch(self.root)
        sound = self.root / 'src/synthesizer.cpp'
        modern = sound.read_text()
        old = previous_synthesizer_bytes(modern, 4096)
        self.assertEqual(hashlib.sha256(old.encode()).hexdigest(),
                         patcher.PREVIOUS_SYNTHESIZER_PATCHED_SHA)
        sound.write_text(old)
        patcher.patch(self.root)
        self.assertEqual(sound.read_text(), modern)

    def test_8192_audio_patch_upgrades_existing_windows_build(self):
        patcher.patch(self.root)
        sound = self.root / 'src/synthesizer.cpp'
        modern = sound.read_text()
        old = previous_synthesizer_bytes(modern, 8192)
        self.assertEqual(hashlib.sha256(old.encode()).hexdigest(),
                         patcher.SINGLE_PACKET_SYNTHESIZER_PATCHED_SHA)
        sound.write_text(old)
        patcher.patch(self.root)
        self.assertEqual(sound.read_text(), modern)

    def test_monolithic_16384_audio_patch_upgrades_existing_build(self):
        patcher.patch(self.root)
        sound = self.root / 'src/synthesizer.cpp'
        modern = sound.read_text()
        old = previous_synthesizer_bytes(modern, 16384)
        self.assertEqual(hashlib.sha256(old.encode()).hexdigest(),
                         patcher.MONOLITHIC_TWO_PACKET_SYNTHESIZER_PATCHED_SHA)
        sound.write_text(old)
        patcher.patch(self.root)
        self.assertEqual(sound.read_text(), modern)


class SynthesizerPacketCapacityTests(unittest.TestCase):
    def test_existing_build_upgrades_previous_synth_limit(self):
        legacy = (
            'm_audioBuffer.size() < 2000;\n'
            'std::max(0, 2000 - (int)m_audioBuffer.size()),\n'
            'std::array<int16_t, 2000> rendered;\n'
        )
        modern = patcher.upgrade_legacy_synthesizer(legacy)
        self.assertEqual(modern.count('16384'), 3)
        self.assertNotIn('2000', modern)

    def test_current_windows_build_patch_upgrades_to_two_packet_capacity(self):
        legacy = (
            'm_audioBuffer.size() < 4096;\n'
            'std::max(0, 4096 - (int)m_audioBuffer.size()),\n'
            'std::array<int16_t, 4096> rendered;\n'
        )
        modern = patcher.upgrade_legacy_synthesizer(legacy, 4096)
        self.assertEqual(modern.count('16384'), 3)
        self.assertNotIn('4096', modern)

    def test_previous_8192_build_is_eligible_for_safe_upgrade(self):
        legacy = (
            'm_audioBuffer.size() < 8192;\n'
            'std::max(0, 8192 - (int)m_audioBuffer.size()),\n'
            'std::array<int16_t, 8192> rendered;\n'
        )
        modern = patcher.upgrade_legacy_synthesizer(legacy, 8192)
        self.assertEqual(modern.count('16384'), 3)
        self.assertNotIn('8192', modern)

    def test_renderer_publishes_short_chunks_before_entire_batch_is_done(self):
        # A 16,384-frame DSP batch can take longer than the native 30-ms
        # read deadline. Readers must be able to consume each finished chunk
        # without waiting for the rest of that batch to finish rendering.
        vendor = (
            '#include <cassert>\n'
            '    m_inputSamplesRead = 0;\n\n    m_audioBufferSize = 0;\n'
            '        m_inputChannels[i].data.destroy();\n'
            'void Synthesizer::writeInput(const double *data) {\n'
            '    std::unique_lock<std::mutex> lk(m_inputLock);\n'
            '            && m_audioBuffer.size() < 2000;\n'
            '        std::max(0, 2000 - (int)m_audioBuffer.size()),\n'
            '    for (int i = 0; i < n; ++i) {\n'
            '        m_audioBuffer.write(renderAudio(i));\n'
            '    }\n'
        )
        modified = patcher.transformed('synthesizer.cpp', vendor)
        self.assertIn('std::array<int16_t, 1024> rendered;', modified)
        self.assertIn('for (int offset = 0; offset < n; offset += 1024)', modified)
        self.assertIn('renderAudio(offset + i)', modified)
        self.assertNotIn('std::array<int16_t, 16384> rendered;', modified)

    def test_cmake_reconfigures_when_core_patch_changes(self):
        cmake = (ROOT / 'CMakeLists.txt').read_text()
        self.assertIn('CMAKE_CONFIGURE_DEPENDS', cmake)
        self.assertIn('patch_engine_sim_core.py', cmake)

    def test_real_windows_smoke_exercises_motor_town_packet_geometry(self):
        source = (ROOT / 'tests/headless_engine_smoke.cpp').read_text()
        self.assertIn('std::array<std::int16_t, 2205> gamePcm', source)
        self.assertIn('completeGamePackets', source)
        self.assertIn('std::array<std::int16_t, 2955> slowGamePcm', source)
        self.assertIn('completeSlowGamePackets', source)
        self.assertIn('186ms probe frame=', source)
        self.assertIn('completeMaxGamePackets', source)

    def test_windows_ci_runs_full_pinned_patch_migration(self):
        workflow = (ROOT.parent / '.github/workflows/native-headless-windows.yml').read_text()
        self.assertIn('MTES_ENGINE_SIM_SOURCE', workflow)
        self.assertIn('python -m unittest native.tests.test_core_patch -v', workflow)

    def test_patched_audio_thread_can_fill_a_150ms_6615_sample_packet(self):
        # Minimal exact excerpts from the pinned engine-sim synthesizer.
        # The old 2000-sample limit cannot satisfy 50-ms PCM, and the
        # intermediate 4096-sample limit cannot supply 150-ms PCM (6615).
        # The 8192 limit leaves only 1577 samples after one 150-ms read,
        # so buffer a second full game packet to ride over late synth batches.
        vendor = (
            '#include <cassert>\n'
            '    m_inputSamplesRead = 0;\n\n    m_audioBufferSize = 0;\n'
            '        m_inputChannels[i].data.destroy();\n'
            'void Synthesizer::writeInput(const double *data) {\n'
            '    std::unique_lock<std::mutex> lk(m_inputLock);\n'
            '            && m_audioBuffer.size() < 2000;\n'
            '        std::max(0, 2000 - (int)m_audioBuffer.size()),\n'
            '    for (int i = 0; i < n; ++i) {\n'
            '        m_audioBuffer.write(renderAudio(i));\n'
            '    }\n'
        )
        modified = patcher.transformed('synthesizer.cpp', vendor)
        for pattern in (
            r'm_audioBuffer\.size\(\) < (\d+)',
            r'std::max\(0, (\d+) - \(int\)m_audioBuffer\.size\(\)\)',
        ):
            match = re.search(pattern, modified)
            self.assertIsNotNone(match, f'Synthesizer limit absent: {pattern}')
            self.assertGreaterEqual(int(match.group(1)), 2 * 6615,
                'The renderer cannot buffer two 150-ms Motor Town PCM packets')
        self.assertIn('std::array<int16_t, 1024> rendered;', modified)
        self.assertIn('for (int offset = 0; offset < n; offset += 1024)', modified)


if __name__ == "__main__":
    unittest.main()
