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

    def test_machine_vcpkg_root_is_preferred_and_session_is_restored(self):
        script = self.builder()
        self.assertIn("GetEnvironmentVariable('VCPKG_ROOT', $scope)", script)
        self.assertIn('$preferredVcpkg = Get-PreferredVcpkgRoot', script)
        self.assertIn('$originalVcpkgRoot = $env:VCPKG_ROOT', script)
        finally_block = script[script.rindex('finally {'):]
        self.assertIn('$env:VCPKG_ROOT = $originalVcpkgRoot', finally_block)

    def test_build_never_calls_a_vcpkg_exe_after_linking(self):
        # Reported again after --fresh: vcpkg.cmake still resolved its root to the
        # removed C:\Users\666\AppData\Local\vcpkg, and z-applocal exited 9009.
        script = self.builder()
        self.assertIn("-DVCPKG_INSTALLED_DIR=$((Join-Path $vcpkgRoot 'installed')", script)
        self.assertIn("'-DVCPKG_APPLOCAL_DEPS=OFF'", script)
        configure = script.index("Invoke-Checked 'Configure native UE4SS")
        check = script.index('Assert-VcpkgConfiguration $buildDir $vcpkgRoot')
        compile_step = script.index("Invoke-Checked 'Compile and stage native UE4SS DLL'")
        self.assertLess(configure, check)
        self.assertLess(check, compile_step)

    def test_staging_copies_vcpkg_runtime_dlls_without_applocal(self):
        parent = (ROOT / 'ue4ss-parent' / 'CMakeLists.txt').read_text()
        self.assertIn('"${MTES_VCPKG_RUNTIME_BIN}/*.dll"', parent)
        self.assertIn('${mtes_runtime_copy_commands}', parent)
        script = self.builder()
        self.assertIn("-DMTES_VCPKG_RUNTIME_BIN=$(Join-Path $vcpkgRoot 'installed\\x64-windows\\bin')", script)


PWSH = os.environ.get('MTES_TEST_PWSH') or shutil.which('pwsh')
STALE_ROOT = 'C:/Users/666/AppData/Local/vcpkg'
LOCAL_ROOT = r'F:\Documents\Karpuzikov Tools\MotorTown EngineSim Mod\dependencies\vcpkg'


@unittest.skipUnless(PWSH, 'Requires PowerShell 7 (pwsh)')
class StaleVcpkgCacheTests(unittest.TestCase):
    """Runs the builder's own cache check against CMakeCache.txt fixtures."""

    def check(self, cache_lines, command=None, projects=None, vcpkg_root=LOCAL_ROOT, extra_env=None):
        command = command or '''
$reason = Get-StaleBuildConfiguration $env:MTES_BUILD $env:MTES_VCPKG
if ($reason) { Write-Output "STALE $reason" } else { Write-Output 'CURRENT' }
'''
        with tempfile.TemporaryDirectory(prefix='MTES builder ') as temp:
            build = Path(temp) / 'build'
            build.mkdir()
            if cache_lines is not None:
                (build / 'CMakeCache.txt').write_text('\n'.join(cache_lines) + '\n')
            for relative, text in (projects or {}).items():
                (build / relative).parent.mkdir(parents=True, exist_ok=True)
                (build / relative).write_text(text)
            script = Path(temp) / 'check.ps1'
            script.write_text('''
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:MTES_BUILDER, [ref]$null, [ref]$null)
foreach ($name in @('Get-CMakeCacheValue', 'Test-SamePath', 'Test-PathUnder', 'Get-StaleBuildConfiguration',
                   'Assert-VcpkgConfiguration', 'Select-VcpkgRoot', 'Get-PreferredVcpkgRoot')) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($fn.Count -ne 1) { throw "Missing builder function $name" }
    . ([scriptblock]::Create($fn[0].Extent.Text))
}
''' + command)
            env = dict(os.environ, MTES_BUILDER=str(BUILDER), MTES_BUILD=str(build), MTES_VCPKG=vcpkg_root,
                       **(extra_env or {}))
            return subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(script)],
                                  env=env, capture_output=True, text=True, timeout=60)

    def stale(self, cache_lines):
        result = self.check(cache_lines)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def test_first_configure_needs_no_fresh(self):
        self.assertEqual(self.stale(None), 'CURRENT')

    def test_reported_stale_user_vcpkg_toolchain_forces_fresh_configure(self):
        output = self.stale([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={STALE_ROOT}/scripts/buildsystems/vcpkg.cmake',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertTrue(output.startswith('STALE vcpkg toolchain'), output)
        self.assertIn(STALE_ROOT, output)

    def test_compiler_removed_by_a_visual_studio_update_forces_fresh_configure(self):
        local = LOCAL_ROOT.replace('\\', '/')
        output = self.stale([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={local}/scripts/buildsystems/vcpkg.cmake',
            'CMAKE_C_COMPILER:FILEPATH=C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/0.0.0/bin/Hostx64/x64/cl.exe',
        ])
        self.assertTrue(output.startswith('STALE compiler'), output)

    def test_cached_packages_alone_do_not_force_fresh_configure(self):
        # VCPKG_INSTALLED_DIR is re-applied with -D on every configure; the user's
        # cache keeps receiving the other value after configure, so this must not
        # turn every incremental build into a fresh configure.
        local = LOCAL_ROOT.replace('\\', '/')
        output = self.stale([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={local}/scripts/buildsystems/vcpkg.cmake',
            f'VCPKG_INSTALLED_DIR:PATH={STALE_ROOT}/installed',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertEqual(output, 'CURRENT')

    def test_matching_cache_keeps_incremental_configure(self):
        # CMake stores forward slashes; the selected root uses backslashes and may differ in case.
        # A different internal Z_VCPKG_ROOT_DIR alone no longer matters: nothing runs its vcpkg.exe.
        local = LOCAL_ROOT.replace('\\', '/')
        output = self.stale([
            f'CMAKE_TOOLCHAIN_FILE:FILEPATH={local.lower()}/scripts/buildsystems/vcpkg.cmake',
            f'VCPKG_INSTALLED_DIR:PATH={local}/installed/',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertEqual(output, 'CURRENT')

    def assert_configuration(self, cache_lines, projects=None):
        return self.check(cache_lines, 'Assert-VcpkgConfiguration $env:MTES_BUILD $env:MTES_VCPKG', projects)

    # The user's cache after 7afe5f2: CMake found Boost in the pinned tree, yet
    # the final cache named the other vcpkg for both values.
    USER_CACHE = [
        f'VCPKG_INSTALLED_DIR:PATH={STALE_ROOT}/installed',
        f'_VCPKG_INSTALLED_DIR:PATH={LOCAL_ROOT.replace(chr(92), "/")}/installed',
        'VCPKG_APPLOCAL_DEPS:BOOL=OFF',
        f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
    ]
    CLEAN_PROJECT = ('<Project><AdditionalIncludeDirectories>'
                     + LOCAL_ROOT + r'\installed\x64-windows\include'
                     + '</AdditionalIncludeDirectories></Project>')

    def test_other_vcpkg_only_in_cache_is_reported_but_accepted(self):
        result = self.assert_configuration(self.USER_CACHE, {
            r'UE4SS\UE4SS.vcxproj': self.CLEAN_PROJECT,
            r'MotorTownEngineSim\MotorTownEngineSim.vcxproj': self.CLEAN_PROJECT,
        })
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Z_VCPKG_ROOT_DIR = '{STALE_ROOT}'", result.stdout)
        self.assertIn(f"VCPKG_INSTALLED_DIR = '{STALE_ROOT}/installed'", result.stdout)
        self.assertIn('Checked 2 generated projects', result.stdout)

    def test_project_using_other_vcpkg_packages_is_refused(self):
        foreign = ('<Project><AdditionalDependencies>'
                   r'C:\Users\666\AppData\Local\vcpkg\installed\x64-windows\lib\boost_filesystem-vc145-mt.lib'
                   '</AdditionalDependencies></Project>')
        result = self.assert_configuration(self.USER_CACHE, {
            r'UE4SS\UE4SS.vcxproj': self.CLEAN_PROJECT,
            r'MotorTownEngineSim\MotorTownEngineSim.vcxproj': foreign,
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MotorTownEngineSim.vcxproj uses another vcpkg', result.stdout + result.stderr)

    def test_project_calling_other_vcpkg_exe_is_refused(self):
        # The exact post-build command from the user's failed build.
        foreign = ('<Project><PostBuildEvent><Command>C:\\Users\\666\\AppData\\Local\\vcpkg\\vcpkg.exe z-applocal '
                   '"--target-binary=F:/x/UE4SS.dll" --installed-bin-dir=C:/Users/666/AppData/Local/vcpkg/installed/x64-windows/bin'
                   '</Command></PostBuildEvent></Project>')
        result = self.assert_configuration(self.USER_CACHE, {r'UE4SS\UE4SS\UE4SS.vcxproj': foreign})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('uses another vcpkg', result.stdout + result.stderr)

    def test_matching_cache_skips_the_project_scan(self):
        local = LOCAL_ROOT.replace('\\', '/')
        result = self.assert_configuration([
            f'VCPKG_INSTALLED_DIR:PATH={local}/installed',
            'VCPKG_APPLOCAL_DEPS:BOOL=OFF',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={local}',
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Note:', result.stdout)

    def test_applocal_calling_a_missing_vcpkg_exe_is_refused(self):
        # The user's cache after bb6079a: applocal reverted to ON, root without vcpkg.exe.
        result = self.assert_configuration([
            f'VCPKG_INSTALLED_DIR:PATH={STALE_ROOT}/installed',
            'VCPKG_APPLOCAL_DEPS:BOOL=ON',
            f'Z_VCPKG_ROOT_DIR:INTERNAL={STALE_ROOT}',
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('applocal is enabled but', result.stdout + result.stderr)

    def test_applocal_with_the_selected_working_vcpkg_is_accepted(self):
        with tempfile.TemporaryDirectory(prefix='MTES vcpkg ') as root:
            (Path(root) / 'vcpkg.exe').write_text('')
            posix = Path(root).as_posix()
            result = self.check([
                f'VCPKG_INSTALLED_DIR:PATH={posix}/installed',
                'VCPKG_APPLOCAL_DEPS:BOOL=ON',
                f'Z_VCPKG_ROOT_DIR:INTERNAL={posix}',
            ], 'Assert-VcpkgConfiguration $env:MTES_BUILD $env:MTES_VCPKG', vcpkg_root=root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('Note:', result.stdout)

    def select(self, preferred, local):
        result = self.check(None, '''
$s = Select-VcpkgRoot $env:MTES_PREFERRED $env:MTES_LOCAL $env:MTES_SYSTEM
Write-Output "$($s.Root)|clone=$($s.Clone)|bootstrap=$($s.Bootstrap)"
''', extra_env={'MTES_PREFERRED': preferred, 'MTES_LOCAL': local,
                     # CI runners really have C:\\vcpkg; keep the test independent of it.
                     'MTES_SYSTEM': str(Path(local) / 'no-system-vcpkg')})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def test_vcpkg_root_checkout_without_exe_is_used_and_bootstrapped(self):
        # The user's VCPKG_ROOT: a complete vcpkg checkout whose vcpkg.exe is missing.
        with tempfile.TemporaryDirectory(prefix='MTES user vcpkg ') as user, \
             tempfile.TemporaryDirectory(prefix='MTES local vcpkg ') as local:
            (Path(user) / '.vcpkg-root').write_text('')
            self.assertEqual(self.select(user, local), f'{user}|clone=False|bootstrap=True')
            (Path(user) / 'vcpkg.exe').write_text('')
            self.assertEqual(self.select(user, local), f'{user}|clone=False|bootstrap=False')

    def test_without_a_vcpkg_root_checkout_the_project_vcpkg_is_used(self):
        with tempfile.TemporaryDirectory(prefix='MTES not vcpkg ') as other, \
             tempfile.TemporaryDirectory(prefix='MTES local vcpkg ') as local:
            missing = str(Path(local) / 'vcpkg')
            self.assertEqual(self.select(other, missing), f'{missing}|clone=True|bootstrap=True')
            self.assertEqual(self.select('', missing), f'{missing}|clone=True|bootstrap=True')


if __name__ == '__main__':
    unittest.main()
