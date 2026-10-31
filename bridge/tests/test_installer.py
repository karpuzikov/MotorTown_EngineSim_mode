"""Checks the released BAT delivers the intended CMake configuration."""

import base64
import gzip
import importlib.util
import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def embedded_installer() -> str:
    bat = (ROOT / "Install-MotorTownEngineSim.bat").read_text(encoding="utf-8")
    payload = bat.split(":MTES_PAYLOAD_BEGIN", 1)[1]
    return gzip.decompress(base64.b64decode(payload.strip())).decode("utf-8")


class InstallerTests(unittest.TestCase):
    def test_bat_runtime_patch_matches_the_tested_source_patch(self):
        spec = importlib.util.spec_from_file_location("patch_engine_sim", ROOT / "bridge/patch_engine_sim.py")
        patcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(patcher)
        match = re.search(r"\$runtimePatch = Decode '([^']+)'", embedded_installer())
        self.assertIsNotNone(match, "BAT does not deliver startup diagnostics")
        actual = json.loads(gzip.decompress(base64.b64decode(match.group(1))))
        self.assertEqual(actual, patcher.runtime_spec())

    def test_bat_delivers_the_standalone_powershell_installer(self):
        source = (ROOT / "Install-MotorTownEngineSim.ps1").read_text(encoding="utf-8")
        self.assertEqual(embedded_installer().replace("\r\n", "\n"), source.replace("\r\n", "\n"))

    def test_cmake_configure_passes_legacy_googletest_policy_flag(self):
        # This is the actual command in the BAT, not a separate mock command.
        configure = embedded_installer().split("Run $cmake @('-S'", 1)[1].split("Run $cmake @('--build'", 1)[0]
        self.assertIn("'-DCMAKE_POLICY_VERSION_MINIMUM=3.5'", configure)

    def test_build_installs_sdl_development_libraries_and_static_boost(self):
        installer = embedded_installer()
        for required in (
            "SDL2-devel-2.32.10-VC.zip",
            "SDL2_image-devel-2.8.8-VC.zip",
            "boost-filesystem:x64-windows-static-md",
            "-DSDL2_INCLUDE_DIR=",
            "-DSDL2_LIBRARY=",
            "-DSDL2_IMAGE_INCLUDE_DIR=",
            "-DSDL2_IMAGE_LIBRARY=",
            "-DCMAKE_TOOLCHAIN_FILE=",
            "-DVCPKG_TARGET_TRIPLET=x64-windows-static-md",
        ):
            with self.subTest(required=required):
                self.assertTrue(required in installer, "Missing installer dependency: " + required)

    def test_piranha_path_uses_supported_boost_absolute_path_method(self):
        installer = embedded_installer()
        self.assertTrue(
            "$piranhaText.Replace('m_path->is_complete()', 'm_path->is_absolute()')" in installer,
            "Piranha needs the Boost.Filesystem is_complete -> is_absolute migration",
        )

    def test_legacy_directx_runtime_is_installed_before_launch(self):
        installer = embedded_installer()
        self.assertIn("function Install-LegacyDirectX {", installer)
        directx = installer.split("function Install-LegacyDirectX {", 1)[1].split("\nfunction ", 1)[0]
        for required in (
            "download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
            "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b",
            "Get-FileHash",
            "DXSETUP.exe",
            '/Q /C /T:',
            "Run $setup @('/silent')",
        ):
            with self.subTest(required=required):
                self.assertIn(required, directx)
        install_call = installer.index("    Install-LegacyDirectX\n")
        launch_call = installer.index("        Start-EngineSimulator $engineExe $build")
        self.assertLess(install_call, launch_call)


if __name__ == "__main__":
    unittest.main()
