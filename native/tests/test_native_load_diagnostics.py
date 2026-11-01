"""A missing imported DLL must be named, even when UE4SS reports only 0x7e."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'ue4ss-parent/diagnose_native_load.py'


class NativeLoadDiagnosticsTests(unittest.TestCase):
    def test_reports_missing_transitive_import_and_staged_dll_inventory(self):
        with tempfile.TemporaryDirectory(prefix='MTES native load ') as directory:
            root = Path(directory)
            game = root / 'Motor Town/Win64'
            dlls = game / 'ue4ss/Mods/MotorTownEngineSim/dlls'
            dlls.mkdir(parents=True)
            (dlls / 'main.dll').write_bytes(b'native module fixture')
            (dlls / 'boost_filesystem-vc143-mt-x64-1_92.dll').write_bytes(b'boost fixture')
            (game / 'ue4ss/UE4SS.dll').write_bytes(b'ue4ss fixture')
            stage = root / 'work/build/UE4SS/dev-stage/ue4ss/Mods/MotorTownEngineSim/dlls'
            stage.mkdir(parents=True)
            (stage / 'main.dll').write_bytes(b'native module fixture')
            if os.name == 'nt':
                fake_dumpbin = root / 'fake_dumpbin.cmd'
                fake_dumpbin.write_text(
                    '@echo off\n'
                    'echo Image has the following dependencies:\n'
                    'if /I "%~nx2"=="main.dll" (\n'
                    ' echo     UE4SS.dll\n'
                    ' echo     boost_filesystem-vc143-mt-x64-1_92.dll\n'
                    ' echo     api-ms-win-core-file-l1-1-0.dll\n'
                    ') else if /I "%~nx2"=="boost_filesystem-vc143-mt-x64-1_92.dll" (\n'
                    ' echo     absent_helper.dll\n'
                    ')\n')
            else:
                fake_dumpbin = root / 'fake_dumpbin.py'
                fake_dumpbin.write_text(
                    '#!/usr/bin/env python3\n'
                    'import os,sys\n'
                    'name = os.path.basename(sys.argv[-1]).lower()\n'
                    'print("Image has the following dependencies:")\n'
                    'if name == "main.dll":\n'
                    ' print("    UE4SS.dll")\n'
                    ' print("    boost_filesystem-vc143-mt-x64-1_92.dll")\n'
                    ' print("    api-ms-win-core-file-l1-1-0.dll")\n'
                    'elif name.startswith("boost_"):\n'
                    ' print("    absent_helper.dll")\n')
            fake_dumpbin.chmod(0o755)
            finished = subprocess.run(
                [sys.executable, str(SCRIPT), '--game-win64', str(game),
                 '--work', str(root / 'work'), '--dumpbin', str(fake_dumpbin)],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
            self.assertIn('MISSING absent_helper.dll (imported by boost_filesystem-vc143-mt-x64-1_92.dll)',
                          finished.stdout)
            self.assertIn('MATCH installed main.dll == staged main.dll', finished.stdout)
            self.assertIn('boost_filesystem-vc143-mt-x64-1_92.dll', finished.stdout)
            self.assertNotIn('MISSING api-ms-win', finished.stdout)
            self.assertTrue(list((root / 'work/logs').glob('NativeLoad_*.txt')))


if __name__ == '__main__':
    unittest.main()
