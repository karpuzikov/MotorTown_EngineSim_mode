"""Exercise the *actual* UE4SS Lua lease code with mocked Unreal audio objects."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua'
HARNESS = ROOT / 'bridge/tests/mute_lease_harness.lua'


@unittest.skipUnless(shutil.which('g++') and Path('/lib/x86_64-linux-gnu/liblua5.4.so.0').is_file(),
                     'Requires system Lua 5.4 and a C++ compiler')
class MuteLeaseLuaTests(unittest.TestCase):
    def test_verified_engine_cue_ack_watchdog_and_original_gain(self):
        with tempfile.TemporaryDirectory(prefix='mtes-lua-lease-') as directory:
            temp = Path(directory)
            runner = temp / 'runner'
            compiled = subprocess.run([
                'g++', '-std=c++17', str(ROOT / 'bridge/tests/lua_runner.cpp'),
                '-l:liblua5.4.so.0', '-o', str(runner),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            script = SCRIPT.read_text()
            anchor = 'local function tick()'
            self.assertEqual(script.count(anchor), 1)
            script = script.replace(anchor,
                '_G.__test_mute = mute_lease_tick\n_G.__test_session = nativeSession\n_G.__test_silence = silence_stock_engine_sounds\n_G.__test_mix = stock_mix\n' + anchor)
            program = temp / 'test.lua'
            program.write_text('''LoopInGameThreadWithDelay = function() end
''' + script + '\n' + HARNESS.read_text())
            prefix = str(temp / 'lease')
            env = {**os.environ, 'TMP': prefix, 'MTES_TEST_PREFIX': prefix}
            run = subprocess.run([str(runner), str(program)], env=env,
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            # Linux uses '\\' literally; remove these test-generated files.
            for path in temp.glob('lease\\MotorTownEngineSim_*'):
                path.unlink()
