"""Exercise the actual parent CMake build/staging contract with tiny local targets.

This tests CMake wiring, not the real UE4SS ABI or Motor Town DLL loading.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PARENT = ROOT / 'ue4ss-parent'
CMAKE = os.environ.get('MTES_TEST_CMAKE') or shutil.which('cmake')


@unittest.skipUnless(CMAKE, 'Requires CMake and a C++ compiler')
class UE4SSParentBuildTests(unittest.TestCase):
    def configure(self, ue4ss, native, build, runtime_bin=None, shipping=False):
        command = [
            CMAKE, '-S', str(PARENT), '-B', str(build),
            f'-DMTES_UE4SS_SOURCE={ue4ss}', f'-DMTES_NATIVE_SOURCE={native}',
        ]
        if shipping:
            command.extend([
                '-DCMAKE_BUILD_TYPE=Game__Shipping__Win64',
                '-DCMAKE_CONFIGURATION_TYPES=Game__Shipping__Win64;Release',
            ])
        if runtime_bin is not None:
            command.append(f'-DMTES_VCPKG_RUNTIME_BIN={runtime_bin}')
        return subprocess.run(command, text=True, capture_output=True, timeout=30)

    def test_source_parent_builds_and_stages_a_mod_without_installing_game_files(self):
        with tempfile.TemporaryDirectory(prefix='MTES UE4SS parent ') as directory:
            temp = Path(directory)
            ue4ss, native, build = temp / 'UE4SS source', temp / 'Native mod', temp / 'build'
            (ue4ss / 'UE4SS/include/Mod').mkdir(parents=True)
            (ue4ss / 'UE4SS/include/Mod/CppUserModBase.hpp').write_text('// ABI header fixture\n')
            (ue4ss / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.22)\n'
                'project(FakeUE4SS LANGUAGES CXX)\n'
                'add_library(UE4SS INTERFACE)\n'
            )
            native.mkdir()
            sim = native / 'sim-fixture'
            (sim / 'es/sound-library').mkdir(parents=True)
            (sim / 'assets/engines/atg-video-2').mkdir(parents=True)
            (sim / 'es/sound-library/smooth').mkdir(parents=True)
            (sim / 'es/engine_sim.mr').write_text('// fake script library\n')
            (sim / 'assets/engines/atg-video-2/07_gm_ls.mr').write_text('// fake V8\n')
            (sim / 'es/sound-library/smooth/smooth_39.wav').write_bytes(
                b'fixture IR bytes must survive staging unchanged')
            (sim / 'LICENSE').write_text('// fake license\n')
            (native / 'mod.cpp').write_text(
                '#if defined(_WIN32)\n'
                '#define MTES_TEST_EXPORT __declspec(dllexport)\n'
                '#else\n'
                '#define MTES_TEST_EXPORT\n'
                '#endif\n'
                'extern "C" MTES_TEST_EXPORT int native_entry() { return 7; }\n'
            )
            (native / 'CMakeLists.txt').write_text(
                f'set_property(GLOBAL PROPERTY MTES_ENGINE_SIM_SOURCE_DIR "{sim.as_posix()}")\n'
                'add_library(MotorTownEngineSim SHARED mod.cpp)\n'
                'target_link_libraries(MotorTownEngineSim PRIVATE UE4SS)\n'
                'add_library(ImportedBoost STATIC IMPORTED)\n'
                'set_target_properties(ImportedBoost PROPERTIES\n'
                '  IMPORTED_CONFIGURATIONS "DEBUG;RELEASE"\n'
                '  IMPORTED_LOCATION_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/debug-boost.lib"\n'
                '  IMPORTED_LOCATION_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/release-boost.lib")\n'
                'file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/boost-$<CONFIG>.txt"\n'
                '  CONTENT "$<TARGET_FILE:ImportedBoost>")\n'
            )
            runtime_bin = temp / 'vcpkg deps/bin'
            runtime_bin.mkdir(parents=True)
            boost_dll = 'boost_filesystem-vc143-mt-x64-1_92.dll'
            (runtime_bin / boost_dll).write_bytes(b'fake Boost dynamic runtime')
            (runtime_bin / 'not-a-runtime.txt').write_text('do not bundle me')
            configured = self.configure(ue4ss, native, build, runtime_bin, shipping=True)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            selected = build / 'boost-Game__Shipping__Win64.txt'
            self.assertEqual(Path(selected.read_text()).name, 'release-boost.lib',
                             'Shipping must never import the debug Boost runtime')
            compiled = subprocess.run([CMAKE, '--build', str(build), '--config', 'Release',
                                       '--target', 'mtes-stage-dev'],
                                      text=True, capture_output=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)

            suffix = '.dll' if os.name == 'nt' else '.so'
            staged = build / 'dev-stage/ue4ss/Mods/MotorTownEngineSim/dlls' / ('main' + suffix)
            self.assertTrue(staged.is_file(), f'Missing staged C++ mod: {staged}')
            self.assertGreater(staged.stat().st_size, 0)
            self.assertEqual((staged.parent / boost_dll).read_bytes(),
                             b'fake Boost dynamic runtime')
            self.assertFalse((staged.parent / 'not-a-runtime.txt').exists())
            package = staged.parent.parent
            self.assertTrue((package / 'Scripts/main.lua').is_file())
            self.assertTrue((package / 'engine_profiles.tsv').is_file())
            self.assertIn('vehicle\t^dory\tassets/es_ford_flathead_239__1948_ford_f_1.mr'
                          '#exhaust=exhaust/lp1_535.wav\t99-100000',
                          (package / 'engine_families.tsv').read_text())
            # Each rule's own exhaust response is staged with the profiles and
            # survives the Engine Simulator library being merged over them: a
            # rule naming a missing file voids the whole manifest in game.
            self.assertEqual(
                (package / 'assets/sound-library/exhaust/lp1_535.wav').read_bytes(),
                (ROOT / 'profiles/sound-library/exhaust/lp1_535.wav').read_bytes())
            self.assertTrue((package / 'assets/es_ford_flathead_239__1948_ford_f_1.mr').is_file())
            self.assertTrue((package / 'assets/es_lambo_l539_65.mr').is_file())
            self.assertTrue((package / 'assets/es_volvo_d13.boost.json').is_file())  # turbo boost travels with it
            self.assertTrue((package / 'engine_families.tsv').is_file())
            self.assertIn('volume', (package / 'settings.ini').read_text())
            self.assertFalse((package / 'assets/engines').exists())  # profiles are self-contained
            self.assertEqual(
                (package / 'assets/sound-library/smooth/smooth_39.wav').read_bytes(),
                b'fixture IR bytes must survive staging unchanged')
            self.assertTrue((package / 'es/engine_sim.mr').is_file())
            self.assertTrue((package / 'ENGINE_SIM_LICENSE.txt').is_file())
            self.assertFalse((temp / 'MotorTown').exists(), 'Build must not modify a game installation')

            (sim / 'es/sound-library/smooth/smooth_39.wav').unlink()
            missing_ir = self.configure(ue4ss, native, temp / 'missing-ir-build', runtime_bin)
            self.assertNotEqual(missing_ir.returncode, 0)
            self.assertIn('impulse-response assets', missing_ir.stdout + missing_ir.stderr)

    def test_rejects_missing_sdk_source_and_incompatible_targets(self):
        with tempfile.TemporaryDirectory(prefix='MTES UE4SS reject ') as directory:
            temp = Path(directory)
            ue4ss, native = temp / 'ue4ss', temp / 'native'
            ue4ss.mkdir()
            native.mkdir()
            (native / 'CMakeLists.txt').write_text(
                'add_library(MotorTownEngineSim INTERFACE)\n')
            # A random directory is not a usable UE4SS checkout.
            missing = self.configure(ue4ss, native, temp / 'missing-build')
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('MTES_UE4SS_SOURCE', missing.stdout + missing.stderr)

            (ue4ss / 'UE4SS/include/Mod').mkdir(parents=True)
            (ue4ss / 'UE4SS/include/Mod/CppUserModBase.hpp').write_text('// fixture\n')
            (ue4ss / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.22)\n'
                'project(BrokenUE4SS LANGUAGES CXX)\n'
                'add_library(NotUE4SS INTERFACE)\n')
            incompatible = self.configure(ue4ss, native, temp / 'invalid-build')
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertIn('UE4SS target', incompatible.stdout + incompatible.stderr)

            (ue4ss / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.22)\n'
                'project(FakeUE4SS LANGUAGES CXX)\n'
                'add_library(UE4SS INTERFACE)\n')
            missing_mod = self.configure(ue4ss, native, temp / 'missing-mod-build')
            self.assertNotEqual(missing_mod.returncode, 0)
            self.assertIn('MotorTownEngineSim must be a shared library',
                          missing_mod.stdout + missing_mod.stderr)
