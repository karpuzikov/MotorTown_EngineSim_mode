"""Checks the released BAT delivers the intended CMake configuration."""

import base64
import gzip
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def embedded_installer() -> str:
    bat = (ROOT / "Install-MotorTownEngineSim.bat").read_text(encoding="utf-8")
    payload = bat.split(":MTES_PAYLOAD_BEGIN", 1)[1]
    return gzip.decompress(base64.b64decode(payload.strip())).decode("utf-8")


class InstallerTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
