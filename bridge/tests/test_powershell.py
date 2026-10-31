"""Execute installer functions without running Windows setup or downloading anything."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_runtime_patch import fixture, patcher, ORIGINAL_APP


ROOT = Path(__file__).resolve().parents[2]
PWSH = os.environ.get("MTES_TEST_PWSH") or shutil.which("pwsh") or shutil.which("powershell.exe")


def run_powershell(directory, command, **environment):
    script = directory / "test-installer-functions.ps1"
    script.write_text('''
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:MTES_TEST_INSTALLER, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }
$names = @('Say','Ensure','Run','Decode','Write-UTF8','Ensure-EngineSource','Install-RuntimeDiagnostics','Start-EngineSimulator','Repair-DirectXLinkage','Assert-ReleaseDirectXDependencies')
foreach ($name in $names) {
    $fn = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($fn.Count -ne 1) { throw ('Missing or ambiguous installer function: ' + $name) }
    . ([scriptblock]::Create($fn[0].Extent.Text))
}
$Logs = Join-Path $env:MTES_TEST_ROOT 'logs'
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
''' + command, encoding="utf-8")
    env = dict(os.environ, MTES_TEST_INSTALLER=str(ROOT / "Install-MotorTownEngineSim.ps1"),
               MTES_TEST_ROOT=str(directory), **environment)
    return subprocess.run([PWSH, "-NoLogo", "-NoProfile", "-File", str(script)],
                          cwd=directory, env=env, text=True, capture_output=True, timeout=45)


@unittest.skipUnless(PWSH, "Requires PowerShell (or MTES_TEST_PWSH)")
class PowerShellTests(unittest.TestCase):
    def test_runtime_patch_matches_python_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="MTES spaces ") as temp:
            root = Path(temp)
            py = root / "python"
            ps = root / "powershell"
            py.mkdir()
            ps.mkdir()
            fixture(py, "\r\n")
            fixture(ps, "\r\n")
            patcher.patch_runtime(py)
            result = run_powershell(root, 'Install-RuntimeDiagnostics $env:MTES_TEST_SOURCE\nInstall-RuntimeDiagnostics $env:MTES_TEST_SOURCE', MTES_TEST_SOURCE=str(ps))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for name in ["src/main.cpp", "src/engine_sim_application.cpp", "include/mtes_runtime.h"]:
                self.assertEqual((py / name).read_bytes(), (ps / name).read_bytes(), name)
            self.assertEqual(len(list((ps / "src").glob("*.before-mtes-runtime-*"))), 2)

    def test_runtime_patch_rejects_unknown_source_without_partial_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            source.mkdir()
            fixture(source)
            app = source / "src/engine_sim_application.cpp"
            app.write_text(ORIGINAL_APP.replace("m_engine.CreateGameWindow(settings)", "unknown(settings)"))
            before = (source / "src/main.cpp").read_bytes(), app.read_bytes()
            result = run_powershell(root, 'Install-RuntimeDiagnostics $env:MTES_TEST_SOURCE', MTES_TEST_SOURCE=str(source))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unsupported runtime source layout", result.stderr)
            self.assertEqual(before, ((source / "src/main.cpp").read_bytes(), app.read_bytes()))
            self.assertFalse((source / "include/mtes_runtime.h").exists())

    @unittest.skipUnless(shutil.which("git"), "Requires git")
    def test_source_remote_migration_preserves_checkout_and_fresh_clone_uses_fork(self):
        with tempfile.TemporaryDirectory(prefix="MTES source spaces ") as temp:
            root = Path(temp)
            original = root / "original"
            fork = root / "fork"
            installed = root / "installed"
            fresh = root / "fresh"
            subprocess.run(["git", "init", str(original)], check=True, capture_output=True)
            (original / "engine.txt").write_text("original engine")
            subprocess.run(["git", "-C", str(original), "add", "engine.txt"], check=True)
            subprocess.run(["git", "-C", str(original), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture"], check=True, capture_output=True)
            for path in [fork, installed]:
                subprocess.run(["git", "clone", str(original), str(path)], check=True, capture_output=True)
            (installed / "engine.txt").write_text("keep local patch")
            (installed / "build-mtes").mkdir()
            (installed / "build-mtes/cache.txt").write_text("keep build cache")
            result = run_powershell(root, '''
Ensure-EngineSource $env:MTES_TEST_GIT $env:MTES_TEST_SOURCE $env:MTES_TEST_FORK
Ensure-EngineSource $env:MTES_TEST_GIT $env:MTES_TEST_FRESH $env:MTES_TEST_FORK
''', MTES_TEST_GIT=shutil.which("git"), MTES_TEST_SOURCE=str(installed),
                MTES_TEST_FORK=str(fork), MTES_TEST_FRESH=str(fresh))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path in [installed, fresh]:
                remote = subprocess.check_output(["git", "-C", str(path), "remote", "get-url", "origin"], text=True).strip()
                self.assertEqual(remote, str(fork))
            self.assertEqual((installed / "engine.txt").read_text(), "keep local patch")
            self.assertEqual((installed / "build-mtes/cache.txt").read_text(), "keep build cache")
            self.assertEqual((fresh / "engine.txt").read_text(), "original engine")

    @unittest.skipUnless(shutil.which("g++"), "Requires a native C++ compiler")
    def test_launch_reports_process_failure_and_archives_script_errors(self):
        with tempfile.TemporaryDirectory(prefix="MTES launch spaces ") as temp:
            root = Path(temp)
            cpp = root / "test-app.cpp"
            cpp.write_text('''
#include <cstdlib>
#include <fstream>
#include <chrono>
#include <thread>
int main() {
    if (std::getenv("MTES_TEST_CRASH")) return 42;
    std::ofstream("MotorTownEngineSim_runtime.log") << "RUNTIME FAILED: Synthetic engine failure\\n";
    std::ofstream("error_log.log") << "Synthetic script error\\n";
    std::this_thread::sleep_for(std::chrono::seconds(2));
    return 1;
}
''')
            exe = root / "test-app.exe"
            subprocess.run(["g++", "-std=c++17", str(cpp), "-o", str(exe)], check=True, capture_output=True)
            command = 'Start-EngineSimulator (Get-Item -LiteralPath $env:MTES_TEST_EXE) $env:MTES_TEST_ROOT'
            result = run_powershell(root, command, MTES_TEST_EXE=str(exe))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Synthetic engine failure", result.stdout)
            self.assertIn("Synthetic script error", result.stdout)
            self.assertEqual(len(list((root / "logs").glob("*-error_log.log"))), 1)
            result = run_powershell(root, command, MTES_TEST_EXE=str(exe), MTES_TEST_CRASH="1")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("0x0000002A", result.stderr)
            self.assertNotIn("initialization completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
