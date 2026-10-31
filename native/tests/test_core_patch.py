"""Safely patch a build-only Engine Simulator checkout for repeated vehicle swaps."""
import os
from pathlib import Path
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


@unittest.skipUnless(os.environ.get("MTES_ENGINE_SIM_SOURCE"),
                     "Set MTES_ENGINE_SIM_SOURCE to the pinned Engine Simulator checkout")
class CorePatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mtes-headless-core-")
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        for name in ("simulator.cpp", "piston_engine_simulator.cpp"):
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
        compiler = (self.root / "scripting/src/compiler.cpp").read_text()
        piranha_path = (self.root / "dependencies/submodules/piranha/src/path.cpp").read_text()
        self.assertIn("delete[] m_dynoTorqueSamples;", simulator)
        self.assertIn("m_dynoTorqueSamples = nullptr;", simulator)
        self.assertIn("delete[] m_crankshaftLinks;", piston)
        self.assertIn("m_crankshaftLinks = nullptr;", piston)
        self.assertIn("Simulator::destroy();", piston)
        self.assertNotIn("assert(m_antialiasingFilters == nullptr);", piston)
        self.assertIn("m_compiler->addSearchPath(scriptLibrary.toString());", compiler)
        self.assertIn('std::getenv("MTES_SCRIPT_LOG_PATH")', compiler)
        self.assertIn("return m_path->is_absolute();", piranha_path)
        self.assertNotIn("m_path->is_complete()", piranha_path)
        patcher.patch(self.root)
        self.assertEqual((self.root / "src/simulator.cpp").read_text(), simulator)
        self.assertEqual((self.root / "src/piston_engine_simulator.cpp").read_text(), piston)
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


if __name__ == "__main__":
    unittest.main()
