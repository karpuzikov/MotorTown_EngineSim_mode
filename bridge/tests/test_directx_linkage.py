"""Reproduce Delta's mixed retail/debug linkage with CMake, then verify its repair."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_powershell import PWSH, run_powershell


CMAKE = os.environ.get("MTES_TEST_CMAKE") or shutil.which("cmake")
# Exact D3DX link entries from pinned delta-studio b7d0a046 (MIT).
LINKS = '''    ${D3DX_LIBS}/d3dx9.lib
    ${D3DX_LIBS}/d3dx9d.lib
    ${D3DX_LIBS}/d3dx10d.lib
    ${D3DX_LIBS}/d3dx10.lib
    ${D3DX_LIBS}/d3dx11.lib
    ${D3DX_LIBS}/d3dx11d.lib'''


def cmake_fixture(root):
    path = root / "dependencies/submodules/delta-studio/CMakeLists.txt"
    path.parent.mkdir(parents=True)
    text = '''cmake_minimum_required(VERSION 3.10)
project(MTESLinkage NONE)
set(D3DX_LIBS "${CMAKE_CURRENT_SOURCE_DIR}/lib")
add_library(delta-core INTERFACE)
target_link_libraries(delta-core INTERFACE
''' + LINKS + '''
    ${D3DX_LIBS}/d3dxof.lib
)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/links.txt"
    CONTENT "$<TARGET_GENEX_EVAL:delta-core,$<TARGET_PROPERTY:delta-core,INTERFACE_LINK_LIBRARIES>>")
'''
    path.write_bytes(text.replace("\n", "\r\n").encode())
    return path


def configured_libraries(source, build, config):
    subprocess.run([CMAKE, "-S", str(source), "-B", str(build),
                    "-G", "Unix Makefiles" if os.name != "nt" else "NMake Makefiles",
                    "-DCMAKE_BUILD_TYPE=" + config], check=True, capture_output=True, text=True)
    return {Path(x).name for x in (build / "links.txt").read_text().split(";") if x}


@unittest.skipUnless(PWSH, "Requires PowerShell")
class DirectXLinkageTests(unittest.TestCase):
    @unittest.skipUnless(CMAKE, "Requires CMake (or MTES_TEST_CMAKE)")
    def test_cmake_release_uses_only_retail_d3dx_libraries_after_repair(self):
        with tempfile.TemporaryDirectory(prefix="MTES DirectX spaces ") as temp:
            root = Path(temp)
            path = cmake_fixture(root)
            before = configured_libraries(path.parent, root / "before", "Release")
            self.assertIn("d3dx10d.lib", before, "Fixture must reproduce the reported debug dependency")
            result = run_powershell(root, 'Repair-DirectXLinkage $env:MTES_TEST_ROOT\nRepair-DirectXLinkage $env:MTES_TEST_ROOT')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            release = configured_libraries(path.parent, root / "release", "Release")
            self.assertEqual(release, {"d3dx9.lib", "d3dx10.lib", "d3dx11.lib", "d3dxof.lib"})
            debug = configured_libraries(path.parent, root / "debug", "Debug")
            self.assertEqual(debug, {"d3dx9d.lib", "d3dx10d.lib", "d3dx11d.lib", "d3dxof.lib"})
            self.assertEqual(len(list(path.parent.glob("CMakeLists.txt.before-mtes-directx-*"))), 1)
            raw = path.read_bytes()
            self.assertNotIn(b"\n", raw.replace(b"\r\n", b""))

    def test_unknown_directx_layout_is_not_changed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = cmake_fixture(root)
            path.write_text(path.read_text().replace("d3dx10d.lib", "custom.lib"))
            before = path.read_bytes()
            result = run_powershell(root, 'Repair-DirectXLinkage $env:MTES_TEST_ROOT')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unsupported Delta Studio DirectX link layout", result.stderr)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.glob("*.before-mtes-directx-*")), [])

    def test_built_executable_check_rejects_debug_imports_and_tool_failure(self):
        command = '''
function Test-Dumpbin {
    param($noLogo, $depends, $binary)
    if ($noLogo -ne '/nologo' -or $depends -ne '/dependents' -or $binary -ne 'test engine.exe') { throw 'Bad dumpbin arguments' }
    $global:LASTEXITCODE = [int]$env:MTES_TEST_TOOL_EXIT
    "Image has the following dependencies:"
    "    KERNEL32.dll"
    "    $env:MTES_TEST_IMPORT"
}
Assert-ReleaseDirectXDependencies 'Test-Dumpbin' 'test engine.exe'
'''
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ["d3dx9d_43.dll", "D3DX10d_43.dll", "d3dx11d_43.dll"]:
                with self.subTest(name=name):
                    result = run_powershell(root, command, MTES_TEST_IMPORT=name, MTES_TEST_TOOL_EXIT="0")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Debug DirectX dependency", result.stderr)
                    self.assertIn(name.lower(), result.stderr.lower())
            result = run_powershell(root, command, MTES_TEST_IMPORT="D3DX10_43.dll", MTES_TEST_TOOL_EXIT="0")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = run_powershell(root, command, MTES_TEST_IMPORT="D3DX10_43.dll", MTES_TEST_TOOL_EXIT="3")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dependency inspection failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
