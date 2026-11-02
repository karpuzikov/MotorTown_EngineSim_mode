"""Development installation is scoped, backed up and verifies both code files."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'ue4ss-parent/install-dev-test.ps1'
PWSH = shutil.which('pwsh') or shutil.which('powershell')


class DevInstallerSourceTests(unittest.TestCase):
    def test_requires_game_path_and_does_not_touch_other_mods(self):
        text = SCRIPT.read_text()
        self.assertIn('Mandatory = $true', text)
        self.assertIn('MotorTownEngineSim', text)
        self.assertIn('Get-Process', text)
        self.assertIn('Copy-Item -LiteralPath $target', text)
        self.assertIn('Get-FileHash', text)
        self.assertNotIn('mods.txt', text)
        self.assertNotIn('Remove-Item', text)

    def test_exporter_version_guard_matches_staged_source(self):
        exporter = (SCRIPT.parents[2] / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua').read_text()
        expected = next(line.split('"')[1] for line in exporter.splitlines()
                        if 'log("Exporter v' in line and 'active. Telemetry:' in line)
        self.assertIn("-Pattern '" + expected.split('. Telemetry:')[0] + "'", SCRIPT.read_text())


@unittest.skipUnless(PWSH, 'Requires PowerShell')
class DevInstallerBehaviorTests(unittest.TestCase):
    def test_install_backups_and_verifies_complete_dev_package(self):
        with tempfile.TemporaryDirectory(prefix='MTES dev install ') as temp:
            root = Path(temp)
            stage = root / 'stage'
            game = root / 'Game/Win64'
            mod = game / 'ue4ss/Mods/MotorTownEngineSim'
            backup = root / 'backups'
            for relative in (
                'dlls/main.dll', 'dlls/boost_filesystem-vc143-mt-x64-1_92.dll',
                'Scripts/main.lua', 'enabled.txt',
                'engine_profiles.tsv', 'engine_families.tsv', 'settings.ini',
                'ENGINE_SIM_LICENSE.txt',
                'assets/es_ford_flathead_239.mr', 'assets/es_chevy_350.mr', 'assets/es_volvo_d13.mr',
                'assets/engines/atg-video-2/07_gm_ls.mr',
                'assets/sound-library/smooth/smooth_39.wav',
                'assets/sound-library/new/mild_exhaust.wav',
                'es/engine_sim.mr',
            ):
                path = stage / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('staged:' + relative +
                    ('\nExporter v0.2.24 active' if relative == 'Scripts/main.lua' else ''))
            (mod / 'dlls').mkdir(parents=True)
            (mod / 'dlls/main.dll').write_text('old-original-dll')
            (mod / 'settings.ini').write_text('volume = 0.4\n')
            command = [PWSH, '-NoLogo', '-NoProfile', '-File', str(SCRIPT),
                       '-GameWin64', str(game), '-StageRoot', str(stage),
                       '-BackupRoot', str(backup)]
            finished = subprocess.run(command, capture_output=True, text=True, timeout=20)
            self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
            self.assertEqual((mod / 'dlls/main.dll').read_text(), 'staged:dlls/main.dll')
            self.assertEqual((mod / 'dlls/boost_filesystem-vc143-mt-x64-1_92.dll').read_text(),
                             'staged:dlls/boost_filesystem-vc143-mt-x64-1_92.dll')
            self.assertIn('Exporter v0.2.24 active', (mod / 'Scripts/main.lua').read_text())
            self.assertTrue((mod / 'assets/sound-library/smooth/smooth_39.wav').is_file())
            self.assertTrue((mod / 'engine_families.tsv').is_file())
            self.assertEqual((mod / 'settings.ini').read_text(), 'volume = 0.4\n',
                             "An update must keep the player's volume setting")
            self.assertEqual(len(list(backup.glob('*/MotorTownEngineSim/dlls/main.dll'))), 1)
