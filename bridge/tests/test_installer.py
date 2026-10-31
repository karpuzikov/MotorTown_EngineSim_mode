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


if __name__ == "__main__":
    unittest.main()
