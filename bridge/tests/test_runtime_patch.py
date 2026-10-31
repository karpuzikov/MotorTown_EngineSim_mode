"""Run patched startup against a tiny app boundary; no game or DirectX required."""

import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "patch_engine_sim", Path(__file__).resolve().parents[1] / "patch_engine_sim.py"
)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

# Source anchors from ange-yaghi/engine-sim 85f7c3b (MIT).
ORIGINAL_MAIN = '''#include "../include/engine_sim_application.h"

#include <iostream>

int WINAPI WinMain(
    _In_ HINSTANCE hInstance,
    _In_opt_ HINSTANCE hPrevInstance,
    _In_ LPSTR lpCmdLine,
    _In_ int nCmdShow)
{
    (void)nCmdShow;
    (void)lpCmdLine;
    (void)hPrevInstance;

    EngineSimApplication application;
    application.initialize((void *)&hInstance, ysContextObject::DeviceAPI::DirectX11);
    application.run();
    application.destroy();

    return 0;
}
'''
ORIGINAL_APP = '''#include "../include/engine_sim_application.h"
void EngineSimApplication::initialize() {
    m_engine.CreateGameWindow(settings);
    m_assetManager.CompileInterchangeFile((m_assetPath + "/assets").c_str(), 1.0f, true);
    m_assetManager.LoadSceneFile((m_assetPath + "/assets").c_str(), true);
    const bool compiled = compiler.compile("../assets/main.mr");
#endif /* ATG_ENGINE_SIM_PIRANHA_ENABLED */

    if (vehicle == nullptr) {
    }
    m_simulator->startAudioRenderingThread();
}
// MTES_BRIDGE_V1 stays intact
'''


def fixture(root, newline="\n"):
    (root / "src").mkdir()
    (root / "include").mkdir()
    for name, content in [("main.cpp", ORIGINAL_MAIN), ("engine_sim_application.cpp", ORIGINAL_APP)]:
        (root / "src" / name).write_bytes(content.replace("\n", newline).encode())


class RuntimePatchTests(unittest.TestCase):
    def test_runtime_patch_keeps_telemetry_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root, "\r\n")
            patcher.patch_runtime(root)
            paths = [root / "src/main.cpp", root / "src/engine_sim_application.cpp", root / "include/mtes_runtime.h"]
            before = [p.read_bytes() for p in paths]
            patcher.patch_runtime(root)
            self.assertEqual(before, [p.read_bytes() for p in paths])
            self.assertIn(b"// MTES_BRIDGE_V1 stays intact", before[1])
            self.assertNotIn(b"\n", before[1].replace(b"\r\n", b""))
            self.assertEqual(len(list((root / "src").glob("*.before-mtes-runtime-*"))), 2)

    def test_unknown_source_is_rejected_before_any_files_change(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root)
            app = root / "src/engine_sim_application.cpp"
            app.write_text(ORIGINAL_APP.replace("m_engine.CreateGameWindow(settings)", "unsupported(settings)"))
            original = (root / "src/main.cpp").read_bytes(), app.read_bytes()
            with self.assertRaises(RuntimeError):
                patcher.patch_runtime(root)
            self.assertEqual(original, ((root / "src/main.cpp").read_bytes(), app.read_bytes()))
            self.assertFalse((root / "include/mtes_runtime.h").exists())
            self.assertEqual(list((root / "src").glob("*.before-mtes-runtime-*")), [])

    @unittest.skipUnless(shutil.which("g++"), "Requires a C++17 compiler")
    def test_patched_executable_reports_startup_failure_and_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root)
            patcher.patch_runtime(root)
            # Replace only the external Win32/EngineSim boundary. The emitted
            # WinMain, runtime header, logging and exception handling are real.
            (root / "include/engine_sim_application.h").write_text('''
#pragma once
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#define WINAPI
#define _In_
#define _In_opt_
using HINSTANCE = void*;
using LPSTR = char*;
const int MB_OK = 0, MB_ICONERROR = 16;
inline int MessageBoxA(void*, const char* text, const char*, int) {
    std::ofstream("message.txt") << text;
    return 0;
}
struct ysContextObject { enum class DeviceAPI { DirectX11 }; };
struct EngineSimApplication {
    // Delta requires explicit teardown, even when initialization failed.
    bool destroyed = false;
    ~EngineSimApplication() { if (!destroyed) std::abort(); }
    void initialize(void*, ysContextObject::DeviceAPI) {
        if (std::getenv("MTES_TEST_FAILURE")) throw std::runtime_error("Synthetic shader failure");
    }
    void run() { std::ofstream("ran.txt") << "ran"; }
    void destroy() { destroyed = true; }
};
''')
            (root / "src/harness.cpp").write_text('''
int WinMain(void*, void*, char*, int);
int main() { return WinMain(nullptr, nullptr, nullptr, 0); }
''')
            exe = root / "runtime-test"
            subprocess.run(["g++", "-std=c++17", str(root / "src/main.cpp"),
                            str(root / "src/harness.cpp"), "-o", str(exe)], check=True, capture_output=True, text=True)
            import os
            env = dict(os.environ, MTES_TEST_FAILURE="1")
            result = subprocess.run([str(exe)], cwd=root, env=env)
            self.assertEqual(result.returncode, 1)
            log = (root / "MotorTownEngineSim_runtime.log").read_text()
            self.assertIn("Synthetic shader failure", log)
            self.assertNotIn("MTES_STARTUP_READY", log)
            self.assertIn("Synthetic shader failure", (root / "message.txt").read_text())
            self.assertFalse((root / "ran.txt").exists())
            env.pop("MTES_TEST_FAILURE")
            result = subprocess.run([str(exe)], cwd=root, env=env)
            self.assertEqual(result.returncode, 0)
            log = (root / "MotorTownEngineSim_runtime.log").read_text()
            self.assertIn("MTES_STARTUP_READY", log)
            self.assertNotIn("Synthetic shader failure", log)
            self.assertTrue((root / "ran.txt").is_file())


if __name__ == "__main__":
    unittest.main()
