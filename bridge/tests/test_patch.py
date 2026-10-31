import tempfile
import unittest
from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location("patch_engine_sim", Path(__file__).resolve().parents[1] / "patch_engine_sim.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PatchTests(unittest.TestCase):
    def test_patch_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'src').mkdir()
            file = root/'src'/'engine_sim_application.cpp'
            file.write_text('int a = 1;\nvoid EngineSimApplication::processEngineInput() {\n  int c = 2;\n}\n\nvoid EngineSimApplication::renderScene() {\n}\n')
            module.patch(root)
            s = file.read_text()
            self.assertIn('readMtTelemetry(mt)', s)
            self.assertIn('m_simulator->m_dyno.m_hold = on;', s)
            self.assertEqual(s.count(module.MARK), 2)
            module.patch(root)
            self.assertEqual(file.read_text(), s)
            self.assertEqual(len(list((root/'src').glob('*.before-mtes-*'))), 1)

    def test_refuse_unknown_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'src').mkdir()
            (root/'src'/'engine_sim_application.cpp').write_text('unexpected file')
            with self.assertRaises(RuntimeError):
                module.patch(root)

if __name__ == '__main__': unittest.main()
