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


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("g++"), "Requires a C++ compiler")
class NativeModTests(unittest.TestCase):
    def test_mod_exports_lifecycle_without_launching_a_companion(self):
        source = ROOT / "src/dllmain.cpp"
        self.assertTrue(source.is_file())
        text = source.read_text()
        self.assertIn('STR("MotorTownEngineSim")', text)
        self.assertNotIn("CreateProcess", text)
        self.assertNotIn("ShellExecute", text)
        self.assertNotIn("SDL_CreateWindow", text)
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
            target = Path(temp) / "mod.so"
            result = subprocess.run(
                ["g++", "-std=c++20", "-shared", "-fPIC", "-I", temp,
                 str(source), "-o", str(target)], capture_output=True, text=True,
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


if __name__ == "__main__":
    unittest.main()
