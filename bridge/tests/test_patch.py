import tempfile
import unittest
from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location("patch_engine_sim", Path(__file__).resolve().parents[1] / "patch_engine_sim.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ORIGINAL_SOURCE = (Path(__file__).parent / 'fixtures/original_engine_input.cpp').read_text()
ORIGINAL_BODY = ORIGINAL_SOURCE[len(module.FUNCTION_START):ORIGINAL_SOURCE.index(module.FUNCTION_END)]

class PatchTests(unittest.TestCase):
    def test_existing_v1_patch_is_upgraded_instead_of_skipped(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'src').mkdir()
            file = root / 'src/engine_sim_application.cpp'
            legacy = (Path(__file__).parent / 'fixtures/legacy_bridge_override.cpp').read_text()
            old = module.HEADER + '\n' + ORIGINAL_SOURCE.replace(module.FUNCTION_END, legacy + module.FUNCTION_END)
            file.write_bytes(old.replace('\n', '\r\n').encode())
            module.patch(root)
            updated = file.read_bytes()
            self.assertNotIn(b'm_engine.IsKeyDown', updated)
            self.assertNotIn(b'mtWasConnected', updated)
            self.assertNotIn(b'\n', updated.replace(b'\r\n', b''))
            module.patch(root)
            self.assertEqual(updated, file.read_bytes())

    def test_changed_legacy_patch_is_rejected_without_overwriting_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'src').mkdir()
            file = root / 'src/engine_sim_application.cpp'
            legacy = (Path(__file__).parent / 'fixtures/legacy_bridge_override.cpp').read_text()
            legacy = legacy.replace('mtWasConnected = true;', 'mtWasConnected = false;')
            old = module.HEADER + '\n' + module.FUNCTION_START + legacy + module.FUNCTION_END + '\n}\n'
            file.write_text(old)
            with self.assertRaises(RuntimeError):
                module.patch(root)
            self.assertEqual(file.read_text(), old)

    def test_changed_original_controls_are_not_discarded_during_upgrade(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'src').mkdir()
            file = root / 'src/engine_sim_application.cpp'
            legacy = (Path(__file__).parent / 'fixtures/legacy_bridge_override.cpp').read_text()
            original = ORIGINAL_SOURCE.replace('m_targetSpeedSetting = 0.1;', 'm_targetSpeedSetting = 0.35;')
            old = module.HEADER + '\n' + original.replace(module.FUNCTION_END, legacy + module.FUNCTION_END)
            file.write_text(old)
            with self.assertRaises(RuntimeError):
                module.patch(root)
            self.assertEqual(file.read_text(), old)

    def test_patch_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'src').mkdir()
            file = root/'src'/'engine_sim_application.cpp'
            file.write_text('int a = 1;\n' + ORIGINAL_SOURCE)
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
