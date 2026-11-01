"""Regression checks for the optional one-command local UE4SS build path.

The PowerShell parser / plan-only execution runs on GitHub's Windows runner.
These portable checks protect the source revision and safety contract.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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

    def test_cmake_4_handles_old_google_test_policy_minimum(self):
        # Reproduced on Windows with CMake 4.4: the fetched GoogleTest tree
        # declares a pre-3.5 minimum and CMake refuses to configure it.
        self.assertIn('-DCMAKE_POLICY_VERSION_MINIMUM=3.5', self.builder())

    def test_windows_ci_parses_and_dry_runs_the_builder_without_private_source(self):
        content = CI.read_text()
        self.assertIn('build-local.ps1', content)
        self.assertIn('Parser]::ParseFile', content)
        self.assertIn('-PlanOnly', content)

    def test_selected_vcpkg_is_exported_and_stale_cache_is_reconfigured(self):
        # Reported: CMake reused a cache from C:\Users\666\AppData\Local\vcpkg,
        # whose vcpkg.exe no longer exists, so post-build z-applocal exited 9009.
        script = self.builder()
        self.assertIn('$env:VCPKG_ROOT = $vcpkgRoot', script)
        self.assertLess(script.index('$env:VCPKG_ROOT = $vcpkgRoot'),
                        script.index("'install', 'sdl2:x64-windows'"))
        self.assertIn("$cmakeArgs = @('--fresh') + $cmakeArgs", script)
        self.assertLess(script.index("@('--fresh') + $cmakeArgs"),
                        script.index("Invoke-Checked 'Configure native UE4SS"))


PWSH = os.environ.get('MTES_TEST_PWSH') or shutil.which('pwsh')
STALE_ROOT = 'C:/Users/666/AppData/Local/vcpkg'
LOCAL_ROOT = r'F:\Documents\Karpuzikov Tools\MotorTown EngineSim Mod\dependencies\vcpkg'


@unittest.skipUnless(PWSH, 'Requires PowerShell 7 (pwsh)')
class StaleVcpkgCacheTests(unittest.TestCase):
    """Runs the builder's own cache check against CMakeCache.txt fixtures."""

    def check(self, cache_lines):
        with tempfile.TemporaryDirectory(prefix='MTES builder ') as temp:
            build = Path(temp) / 'build'
            build.mkdir()
            if cache_lines is not None:
                (build / 'CMakeCache.txt').write_text('\n'.join(cache_lines) + '\n')
            script = Path(temp) / 'check.ps1'
            script.write_text('''
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:MTES_BUILDER, [ref]$null, [ref]$null)
foreach ($name in @('Get-CMakeCacheValue', 'Test-SamePath', 'Get-StaleVcpkgConfiguration')) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($fn.Count -ne 1) { throw "Missing builder function $name" }
    . ([scriptblock]::Create($fn[0].Extent.Text))
}
$reason = Get-StaleVcpkgConfiguration $env:MTES_BUILD $env:MTES_VCPKG
if ($reason) { Write-Output "STALE $reason" } else { Write-Output 'CURRENT' }
''')
            env = dict(os.environ, MTES_BUILDER=str(BUILDER), MTES_BUILD=str(build), MTES_VCPKG=LOCAL_ROOT)
            result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(script)],
                                    env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout.strip()

    def test_first_configure_needs_no_fresh(self):
        self.assertEqual(self.check(None), 'CURRENT')

    def test_reported_stale_user_vcpkg_toolchain_forces_fresh_configure(self):
        output = self.check([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={STALE_ROOT}/scripts/buildsystems/vcpkg.cmake',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertTrue(output.startswith('STALE toolchain'), output)
        self.assertIn(STALE_ROOT, output)

    def test_cached_root_alone_is_detected_even_with_matching_toolchain(self):
        local = LOCAL_ROOT.replace('\\', '/')
        output = self.check([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={local}/scripts/buildsystems/vcpkg.cmake',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertTrue(output.startswith('STALE vcpkg root'), output)

    def test_matching_cache_keeps_incremental_configure(self):
        # CMake stores forward slashes; the selected root uses backslashes and may differ in case.
        local = LOCAL_ROOT.replace('\\', '/')
        output = self.check([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={local.lower()}/scripts/buildsystems/vcpkg.cmake',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={local}/',
        ])
        self.assertEqual(output, 'CURRENT')


if __name__ == '__main__':
    unittest.main()
