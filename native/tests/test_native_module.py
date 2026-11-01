"""Portable ABI smoke test for the future UE4SS in-process module.

Uses a tiny UE4SS boundary double, not the actual game or SDK. The Windows
loader/game test remains mandatory before this DLL can be distributed.
"""

import ctypes
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import os


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = [
    'game_telemetry.cpp', 'audio_pipeline.cpp', 'audio_worker.cpp', 'engine_audio.cpp',
    'game_audio.cpp', 'lua_mute_lease.cpp', 'vehicle_profile.cpp',
    'xaudio2_sink.cpp',
]
RUNTIME_SOURCES = [str(ROOT / 'src' / name) for name in RUNTIME]
FAKE_ENGINE = str(ROOT / 'tests/fake_engine_sim_backend.cpp')


@unittest.skipUnless(shutil.which("g++"), "Requires a C++ compiler")
class NativeModTests(unittest.TestCase):
    def test_mod_exports_lifecycle_without_launching_a_companion(self):
        source = ROOT / "src/dllmain.cpp"
        self.assertTrue(source.is_file())
        text = source.read_text()
        self.assertIn('STR("MotorTownEngineSim")', text)
        self.assertIn('STR("0.3.3-dev")', text)
        self.assertNotIn("CreateProcess", text)
        self.assertNotIn("ShellExecute", text)
        self.assertNotIn("SDL_CreateWindow", text)
        # A real in-game PCM drop must name its cause, even if it lasts
        # less than the five-second periodic stage-report interval.
        self.assertIn('Engine Simulator PCM stopped: {}', text)
        with tempfile.TemporaryDirectory() as temp:
            stub = Path(temp) / "Mod"
            stub.mkdir()
            (stub / "CppUserModBase.hpp").write_text('''
#pragma once
#include <string>
#define STR(value) L##value
namespace RC {
class CppUserModBase {
public:
    std::wstring ModName, ModVersion, ModDescription, ModAuthors;
    virtual ~CppUserModBase() = default;
    virtual auto on_unreal_init() -> void {}
    virtual auto on_update() -> void {}
};
}
''')
            output = Path(temp) / "DynamicOutput"
            output.mkdir()
            (output / "DynamicOutput.hpp").write_text('''
#pragma once
namespace RC {
enum class LogLevel { Verbose, Normal };
struct Output {
    template<LogLevel L, typename... Args>
    static void send(const wchar_t*, Args...) {}
};
}
''')
            target = Path(temp) / "mod.so"
            result = subprocess.run(
                ["g++", "-std=c++20", "-shared", "-fPIC", "-I", temp,
                 '-I', str(ROOT / 'src'), str(source),
                 *RUNTIME_SOURCES, FAKE_ENGINE, "-o", str(target)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            module = ctypes.CDLL(str(target))
            module.start_mod.restype = ctypes.c_void_p
            module.uninstall_mod.argtypes = [ctypes.c_void_p]
            pointer = module.start_mod()
            self.assertTrue(pointer)
            module.uninstall_mod(pointer)

    def test_native_target_uses_ue4ss_instead_of_desktop_simulator(self):
        cmake = (ROOT / "CMakeLists.txt").read_text()
        self.assertIn("add_library(MotorTownEngineSim SHARED", cmake)
        self.assertIn("target_link_libraries(MotorTownEngineSim PRIVATE UE4SS)", cmake)
        self.assertNotIn("engine-sim-app", cmake)

    def test_unreal_update_callback_does_not_advance_slow_audio_backend(self):
        # The slow actual Engine Simulator physics advance must never execute
        # on UE4SS's Unreal update callback. A separate worker owns the PCM
        # and still watches focus while Unreal update callbacks are paused.
        source = (ROOT / 'src/dllmain.cpp').read_text()
        update_body = source.split('auto on_update() -> void override {', 1)[1].split(
            '\n    }\n\nprivate:', 1)[0]
        self.assertNotIn('m_pipeline.process(', update_body)
        self.assertNotIn('m_emitters.cancel()', update_body)
        self.assertIn('m_worker.playing()', update_body)
        self.assertIn('m_worker.stage()', update_body)
        self.assertIn('m_worker.start()', source)
        self.assertIn('m_worker.stop()', source)

    def test_ue4ss_frame_callback_consumes_live_gear_in_same_process(self):
        with tempfile.TemporaryDirectory(prefix='mtes-native-ue4ss-') as temp:
            root = Path(temp)
            mod = root / 'Mod'
            mod.mkdir()
            (mod / 'CppUserModBase.hpp').write_text('''
#pragma once
#include <string>
#define STR(value) L##value
namespace RC {
class CppUserModBase {
public:
    std::wstring ModName, ModVersion, ModDescription, ModAuthors;
    virtual ~CppUserModBase() = default;
    virtual void on_unreal_init() {}
    virtual void on_update() {}
};
}
''')
            dynamic = root / 'DynamicOutput'
            dynamic.mkdir()
            (dynamic / 'DynamicOutput.hpp').write_text('''
#pragma once
#include <vector>
#include <string>
#include <type_traits>
namespace RC {
enum class LogLevel { Verbose, Normal };
struct LogRecord {
    LogLevel level;
    std::wstring message;
    std::vector<double> values;
};
extern std::vector<LogRecord> observed_logs;
struct Output {
    template<typename T>
    static double numeric_value(T value) {
        if constexpr (std::is_arithmetic_v<T>) return static_cast<double>(value);
        else return 0.0;
    }
    template<LogLevel L, typename... Args>
    static void send(const wchar_t* format, Args... args) {
        observed_logs.push_back({L, format, {numeric_value(args)...}});
    }
};
}
''')
            exe = root / 'ue4ss-test'
            other_temp = root / 'other-temp'
            other_temp.mkdir()
            build = subprocess.run([
                'g++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(root), '-I', str(ROOT / 'src'),
                str(ROOT / 'tests/ue4ss_telemetry_test.cpp'),
                str(ROOT / 'src/dllmain.cpp'),
                *RUNTIME_SOURCES, FAKE_ENGINE, '-o', str(exe),
            ], text=True, capture_output=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], env={**os.environ, 'TMP': temp,
                                                 'TEMP': str(other_temp)},
                                 text=True, capture_output=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
