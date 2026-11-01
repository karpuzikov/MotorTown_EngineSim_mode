"""The native side must never claim game engine sound is muted without a fresh Lua ACK."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++20 compiler')
class LuaMuteLeaseTests(unittest.TestCase):
    def test_ack_identity_liveness_and_expiry(self):
        with tempfile.TemporaryDirectory(prefix='mtes-mute-lease-') as temp:
            executable = Path(temp) / 'mute-lease-test'
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/lua_mute_lease_test.cpp'),
                str(ROOT / 'src/lua_mute_lease.cpp'), '-o', str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable), temp], capture_output=True,
                                 text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
