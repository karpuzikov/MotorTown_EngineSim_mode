"""Verify the collector produces one useful report without changing installed files."""

import base64
import gzip
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_powershell import PWSH, ROOT


class DiagnosticPackagingTests(unittest.TestCase):
    def test_single_bat_delivers_the_tested_collector(self):
        bat = (ROOT / "Collect-MotorTownEngineSim-Logs.bat").read_text()
        payload = bat.split(":MTES_PAYLOAD_BEGIN", 1)[1]
        script = gzip.decompress(base64.b64decode(payload)).decode("utf-8")
        self.assertEqual(script, (ROOT / "bridge/collect_diagnostics.ps1").read_text())
        self.assertNotIn("Start-Transcript", script)


@unittest.skipUnless(PWSH, "Requires PowerShell")
class DiagnosticReportTests(unittest.TestCase):
    def collect(self, root, packet, read_failures=False, flood_log=False):
        game = root / "Game with spaces/Win64"
        game.mkdir(parents=True)
        exe = game / "MotorTown-Win64-Shipping.exe"
        exe.write_bytes(b"test fixture")
        ue4ss = game / "ue4ss"
        ue4ss.mkdir()
        (ue4ss / "UE4SS.log").write_text("UE4SS startup\nSynthetic exporter load failure\n")
        mod = ue4ss / "Mods/MotorTownEngineSim"
        (mod / "Scripts").mkdir(parents=True)
        (mod / "Scripts/main.lua").write_text("-- installed exporter\n")
        (mod / "enabled.txt").write_text("")
        (ue4ss / "Mods/mods.txt").write_text("MotorTownEngineSim : 1\n")
        project = root / "Project with spaces"
        build = project / "source/engine-sim/build-mtes"
        build.mkdir(parents=True)
        (build / "MotorTownEngineSim_runtime.log").write_text("MTES_STARTUP_READY\n")
        tempdir = root / "Temp with spaces"
        tempdir.mkdir()
        (tempdir / "MotorTownEngineSim_diagnostics.txt").write_text("Exporter active. Synthetic diagnostic\n")
        if flood_log:
            (tempdir / "MotorTownEngineSim_diagnostics.txt").write_text("Retry mapping: missing\n" * 1000)
        (tempdir / "MotorTownEngineSim_discovery.txt").write_text("Exporter v0.2.9\nMember RetainedEngineState = 5678\n")
        if packet is not None:
            (tempdir / "MotorTownEngineSim_telemetry.txt").write_text(packet)
        original = {p: p.read_bytes() for p in game.rglob("*") if p.is_file()}
        collector = ROOT / "bridge/collect_diagnostics.ps1"
        entry = collector
        if read_failures:
            entry = root / "fail-file-reads.ps1"
            entry.write_text('''param($GamePath, $ProjectPath, [string[]]$TempDirectories, [int]$ObserveSeconds, [switch]$NoOpen)
function Get-Content {
    param($LiteralPath, [int]$Tail, [int]$TotalCount)
    if ([IO.Path]::GetFileName($LiteralPath) -eq 'mods.txt') { throw 'Synthetic list read denied' }
    Microsoft.PowerShell.Management\\Get-Content @PSBoundParameters
}
function Get-FileHash { param($LiteralPath, $Algorithm) throw 'Synthetic exporter hash denied' }
& 'COLLECTOR_PATH' -GamePath $GamePath -ProjectPath $ProjectPath -TempDirectories $TempDirectories -ObserveSeconds $ObserveSeconds -NoOpen:$NoOpen
exit $LASTEXITCODE
'''.replace('COLLECTOR_PATH', str(collector).replace("'", "''")))
        result = subprocess.run([PWSH, "-NoLogo", "-NoProfile", "-File", str(entry),
                                 "-GamePath", str(exe), "-ProjectPath", str(project), "-TempDirectories", str(tempdir),
                                 "-ObserveSeconds", "0", "-NoOpen"], text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reports = list((project / "logs").glob("Connection_*.txt"))
        self.assertEqual(len(reports), 1, result.stdout + result.stderr)
        self.assertEqual(original, {p: p.read_bytes() for p in game.rglob("*") if p.is_file()})
        return reports[0].read_text(), result.stdout

    def test_unreadable_activation_list_and_exporter_hash_do_not_lose_report(self):
        with tempfile.TemporaryDirectory() as temp:
            report, _ = self.collect(Path(temp), None, read_failures=True)
            self.assertIn("Synthetic list read denied", report)
            self.assertIn("Synthetic exporter hash denied", report)
            self.assertIn("Synthetic exporter load failure", report)
            self.assertIn("MTES_STARTUP_READY", report)

    def test_report_contains_game_loader_exporter_and_live_packet(self):
        with tempfile.TemporaryDirectory() as temp:
            packet = f"MTES1 1750.000 0.2500 1 {int(time.time())}\n"
            report, output = self.collect(Path(temp), packet)
            self.assertIn("LIVE game telemetry: RPM=1750", report)
            self.assertIn("Synthetic exporter load failure", report)
            self.assertIn("Synthetic diagnostic", report)
            self.assertIn("MotorTownEngineSim : 1", report)
            self.assertIn("Exporter SHA256:", report)
            self.assertIn("MTES_STARTUP_READY", report)
            self.assertIn("do not prove", report)
            self.assertIn("Report:", output)

    def test_missing_stale_and_invalid_packets_do_not_report_live_connection(self):
        for packet in [None, f"MTES1 2000 0.3 1 {int(time.time()) - 60}",
                       f"MTES1 NaN 0.3 1 {int(time.time())}",
                       f"MTES1 2000 0.3 1 {int(time.time()) + 60}"]:
            with self.subTest(packet=packet), tempfile.TemporaryDirectory() as temp:
                report, output = self.collect(Path(temp), packet)
                self.assertIn("NO LIVE game telemetry", report)
                self.assertNotIn("LIVE game telemetry: RPM=", output)
                self.assertIn("Synthetic exporter load failure", report)

    def test_report_keeps_discovery_snapshot_after_retry_log_flood(self):
        with tempfile.TemporaryDirectory() as temp:
            report, _ = self.collect(Path(temp), None, flood_log=True)
            self.assertIn('Member RetainedEngineState = 5678', report)
            self.assertIn('Retry mapping: missing', report)


if __name__ == "__main__":
    unittest.main()
