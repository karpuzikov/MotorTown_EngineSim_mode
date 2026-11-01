"""Regression checks for the optional one-command local UE4SS build path.

The PowerShell parser / plan-only execution runs on GitHub's Windows runner.
These portable checks protect the source revision and safety contract.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'ue4ss-parent' / 'build-local.ps1'
CI = ROOT.parent / '.github/workflows/native-headless-windows.yml'


class LocalWindowsBuilderTests(unittest.TestCase):
    def builder(self):
        self.assertTrue(BUILDER.is_file(), 'No local Windows builder exists yet')
        return BUILDER.read_text()

    def test_pins_known_ue4ss_revision_and_uses_existing_mod_branch(self):
        script = self.builder()
        self.assertIn('f885e8d2d4dd25258082538f1a9fd56a1c3b1bf1', script)
        self.assertIn('feat/native-engine-audio', script)
        self.assertIn('verify_checkout.py', script)
        self.assertIn('submodule', script)
        self.assertIn('https://github.com/', script)

    def test_uses_isolated_build_dir_and_never_installs_unverified_mod(self):
        script = self.builder()
        self.assertIn('Karpuzikov Tools', script)
        self.assertIn('MotorTown EngineSim Mod', script)
        self.assertIn('Game__Shipping__Win64', script)
        self.assertIn('mtes-stage-dev', script)
        self.assertIn('main.dll', script)
        self.assertIn("$ue4ssSource = Join-Path $WorkDir 'source\\RE-UE4SS'", script)
        self.assertIn("$buildDir = Join-Path $WorkDir 'build\\UE4SS'", script)
        self.assertNotIn('MotorTown-Win64-Shipping.exe', script)

    def test_dependencies_are_local_and_verified(self):
        script = self.builder()
        self.assertIn('vcpkg', script)
        self.assertIn('SDL2', script)
        self.assertIn('win_flex_bison-2.5.25.zip', script)
        self.assertIn('8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135', script)
        self.assertIn('Get-FileHash', script)

    def test_windows_ci_parses_and_dry_runs_the_builder_without_private_source(self):
        content = CI.read_text()
        self.assertIn('build-local.ps1', content)
        self.assertIn('Parser]::ParseFile', content)
        self.assertIn('-PlanOnly', content)


if __name__ == '__main__':
    unittest.main()
