"""Windows reproduction of the user's post-build MSB3073 / exit 9009 failure.

On the user's PC, vcpkg.cmake resolved its internal root (Z_VCPKG_ROOT_DIR) to a
vcpkg whose vcpkg.exe had been removed, even after a fresh configure. Every
shared library then ran that missing vcpkg.exe in its post-build z-applocal step.
build-local.ps1 pins VCPKG_INSTALLED_DIR and disables applocal; this builds a
real DLL with MSBuild both ways against the same broken root.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


VCPKG = Path(os.environ.get('VCPKG_INSTALLATION_ROOT') or r'C:\vcpkg')
TOOLCHAIN = VCPKG / 'scripts' / 'buildsystems' / 'vcpkg.cmake'
CMAKE = shutil.which('cmake')

PROJECT = '''cmake_minimum_required(VERSION 3.22)
project(mtes_applocal_probe LANGUAGES CXX)
add_library(probe SHARED probe.cpp)
'''


@unittest.skipUnless(os.name == 'nt' and CMAKE and TOOLCHAIN.is_file(),
                     'Requires Windows, CMake and a vcpkg installation')
class StaleVcpkgRootBuildTests(unittest.TestCase):
    def build(self, builder_settings):
        temp = Path(tempfile.mkdtemp(prefix='mtes applocal '))
        self.addCleanup(shutil.rmtree, temp, True)
        source = temp / 'src'
        source.mkdir()
        (source / 'CMakeLists.txt').write_text(PROJECT)
        (source / 'probe.cpp').write_text('extern "C" __declspec(dllexport) int mtes_probe() { return 1; }\n')
        removed_root = (temp / 'removed-vcpkg').as_posix()
        args = [CMAKE, '-S', str(source), '-B', str(temp / 'build'), '-A', 'x64',
                f'-DCMAKE_TOOLCHAIN_FILE={TOOLCHAIN}',
                # The root the user's configure kept resolving to: no vcpkg.exe there.
                f'-DZ_VCPKG_ROOT_DIR={removed_root}']
        if builder_settings:
            # Exactly what build-local.ps1 now passes.
            args += [f'-DVCPKG_INSTALLED_DIR={(VCPKG / "installed").as_posix()}', '-DVCPKG_APPLOCAL_DEPS=OFF']
        configure = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(configure.returncode, 0, configure.stdout + configure.stderr)
        return subprocess.run([CMAKE, '--build', str(temp / 'build'), '--config', 'Release'],
                              capture_output=True, text=True)

    def test_stale_root_reproduces_the_reported_post_build_failure(self):
        result = self.build(builder_settings=False)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn('MSB3073', output)
        self.assertIn('removed-vcpkg', output)

    def test_builder_settings_build_despite_stale_root(self):
        result = self.build(builder_settings=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('z-applocal', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
