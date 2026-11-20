"""Preflight a real UE4SS checkout before any Motor Town native DLL build."""

from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / 'ue4ss-parent' / 'verify_checkout.py'


def git(*args, cwd):
    return subprocess.run(['git', *args], cwd=cwd, capture_output=True,
                          text=True, check=True).stdout.strip()


def repository(path):
    path.mkdir(parents=True)
    git('init', '-q', cwd=path)
    git('config', 'user.email', 'native-test@example.invalid', cwd=path)
    git('config', 'user.name', 'Native Test', cwd=path)
    (path / 'README.md').write_text('fixture\n')
    git('add', '.', cwd=path)
    git('commit', '-qm', 'fixture', cwd=path)
    return git('rev-parse', 'HEAD', cwd=path)


class UE4SSCheckoutTests(unittest.TestCase):
    @property
    def module(self):
        self.assertTrue(PREFLIGHT.is_file(), 'UE4SS checkout preflight is not implemented')
        spec = importlib.util.spec_from_file_location('verify_checkout', PREFLIGHT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def make_checkout(self, folder):
        dependency = folder / 'private-submodule-fixture'
        repository(dependency)
        source = folder / 'RE-UE4SS'
        source.mkdir()
        git('init', '-q', cwd=source)
        git('config', 'user.email', 'native-test@example.invalid', cwd=source)
        git('config', 'user.name', 'Native Test', cwd=source)
        (source / 'UE4SS/include/Mod').mkdir(parents=True)
        (source / 'UE4SS/include/Mod/CppUserModBase.hpp').write_text('// fixture\n')
        (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.22)\n')
        git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q',
            str(dependency), 'deps/first/Unreal', cwd=source)
        git('add', '.', cwd=source)
        git('commit', '-qm', 'UE4SS fixture', cwd=source)
        return source, git('rev-parse', 'HEAD', cwd=source)

    def test_initialized_matching_checkout_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, commit = self.make_checkout(Path(temporary))
            self.module.verify_checkout(source, expected_commit=commit)

    def test_wrong_revision_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, _ = self.make_checkout(Path(temporary))
            with self.assertRaisesRegex(ValueError, 'revision mismatch'):
                self.module.verify_checkout(source, expected_commit='0' * 40)

    def test_uninitialized_private_submodule_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, commit = self.make_checkout(Path(temporary))
            clone = Path(temporary) / 'without-submodules'
            git('clone', '-q', '--no-recurse-submodules', str(source), str(clone), cwd=source)
            with self.assertRaisesRegex(ValueError, 'deps/first/Unreal'):
                self.module.verify_checkout(clone, expected_commit=commit)

    def test_non_checkout_does_not_pass_preflight(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'UE4SS source'):
                self.module.verify_checkout(Path(temporary))


class UE4SSWorkflowContractTests(unittest.TestCase):
    def workflow(self):
        path = ROOT.parent / '.github/workflows/native-ue4ss-windows.yml'
        self.assertTrue(path.is_file(), 'Windows native UE4SS DLL job is not implemented')
        return path.read_text()

    def test_windows_job_uses_pinned_source_and_protected_submodules(self):
        workflow = self.workflow()
        self.assertIn('windows-2022', workflow)
        self.assertIn('UE4SS-RE/RE-UE4SS', workflow)
        self.assertIn('f885e8d2d4dd25258082538f1a9fd56a1c3b1bf1', workflow)
        self.assertIn('submodules: recursive', workflow)
        self.assertIn('secrets.UEPSEUDO_PAT', workflow)
        self.assertIn('verify_checkout.py', workflow)
        self.assertNotIn('pull_request:', workflow)

    def test_windows_job_builds_shipping_dll_as_dev_artifact_only(self):
        workflow = self.workflow()
        self.assertIn('Game__Shipping__Win64', workflow)
        self.assertIn('mtes-stage-dev', workflow)
        self.assertIn('main.dll', workflow)
        self.assertIn('actions/upload-artifact@v4', workflow)
        self.assertNotIn('gh release create', workflow)


if __name__ == '__main__':
    unittest.main()
