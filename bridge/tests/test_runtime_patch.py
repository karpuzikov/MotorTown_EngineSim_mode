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
    settings.WindowWidth = 1920;
    settings.WindowHeight = 1080;
    m_engine.CreateGameWindow(settings);
    m_assetManager.CompileInterchangeFile((m_assetPath + "/assets").c_str(), 1.0f, true);
    m_assetManager.LoadSceneFile((m_assetPath + "/assets").c_str(), true);
    const bool compiled = compiler.compile("../assets/main.mr");
#endif /* ATG_ENGINE_SIM_PIRANHA_ENABLED */

    if (vehicle == nullptr) {
    }
    m_simulator->startAudioRenderingThread();
    m_audioSource->SetVolume(1.0f);
}
void EngineSimApplication::process(double frame_dt) {
    double speed = 1.0 / 1.0;
    if (m_engine.IsKeyDown(ysKey::Code::N1)) {
        speed = 1 / 10.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N2)) {
        speed = 1 / 100.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N3)) {
        speed = 1 / 200.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N4)) {
        speed = 1 / 500.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N5)) {
        speed = 1 / 1000.0;
    }

    if (m_engine.IsKeyDown(ysKey::Code::F1)) {
        m_displayAngle += frame_dt * 1.0f;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::F2)) {
        m_displayAngle -= frame_dt * 1.0f;
    }
    else if (m_engine.ProcessKeyDown(ysKey::Code::F3)) {
        m_displayAngle = 0.0f;
    }

    m_simulator->setSimulationSpeed(speed);
}
void EngineSimApplication::run() {
    if (m_engine.ProcessKeyDown(ysKey::Code::Escape)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::Return)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::Tab)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::F)) { ++actions; }
    if (!m_paused || m_engine.ProcessKeyDown(ysKey::Code::Right)) { ++actions; }
}
void EngineSimApplication::configure(const ApplicationSettings &settings) {
    m_applicationSettings = settings;

    if (settings.startFullscreen) {
        m_engine.GetGameWindow()->SetWindowStyle(ysWindow::WindowStyle::Fullscreen);
    }

    m_background = ysColor::srgbiToLinear(m_applicationSettings.colorBackground);
}
// MTES_BRIDGE_V1 stays intact
'''


def fixture(root, newline="\n"):
    (root / "src").mkdir()
    (root / "include").mkdir()
    for name, content in [("main.cpp", ORIGINAL_MAIN), ("engine_sim_application.cpp", ORIGINAL_APP)]:
        (root / "src" / name).write_bytes(content.replace("\n", newline).encode())


class RuntimePatchTests(unittest.TestCase):
    def test_previous_runtime_patch_upgrades_window_and_startup_mute(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root)
            app = root / 'src/engine_sim_application.cpp'
            app.write_bytes((Path(__file__).parent / 'fixtures/runtime_v027_app.cpp').read_bytes())
            patcher.patch_runtime(root)
            text = app.read_text()
            self.assertIn('settings.WindowWidth = 960;', text)
            self.assertIn('settings.WindowHeight = 540;', text)
            self.assertIn('m_audioSource->SetVolume(0.0f);', text)
            self.assertNotIn('if (settings.startFullscreen)', text)
            before = app.read_bytes()
            patcher.patch_runtime(root)
            self.assertEqual(app.read_bytes(), before)

    @unittest.skipUnless(shutil.which('g++'), 'Requires a C++17 compiler')
    def test_script_fullscreen_and_background_keys_do_not_take_over_bridge(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root)
            patcher.patch_runtime(root)
            text = (root / 'src/engine_sim_application.cpp').read_text()
            run = text[text.index('void EngineSimApplication::run()'):text.index('void EngineSimApplication::configure')]
            process = text[text.index('void EngineSimApplication::process(double frame_dt)'):text.index('void EngineSimApplication::run()')]
            configure = text[text.index('void EngineSimApplication::configure'):text.index('    m_background =')]
            harness = root / 'window-test.cpp'
            harness.write_text('''
#include <cassert>
struct ysKey { enum class Code { Escape, Return, Tab, F, Right, N1, N2, N3, N4, N5, F1, F2, F3 }; };
struct ysWindow { enum class WindowStyle { Windowed, Fullscreen }; };
struct ApplicationSettings { bool startFullscreen = true; };
struct Window {
    bool active = false;
    ysWindow::WindowStyle style = ysWindow::WindowStyle::Fullscreen;
    bool IsActive() { return active; }
    void SetWindowStyle(ysWindow::WindowStyle value) { style = value; }
};
struct NativeEngine {
    Window window;
    Window *GetGameWindow() { return &window; }
    bool ProcessKeyDown(ysKey::Code) { return true; }
    bool IsKeyDown(ysKey::Code) { return true; }
};
struct Simulator {
    double speed = 0;
    void setSimulationSpeed(double value) { speed = value; }
};
struct EngineSimApplication {
    NativeEngine m_engine;
    bool m_paused = true;
    int actions = 0;
    float m_displayAngle = 0;
    Simulator sim;
    Simulator *m_simulator = &sim;
    ApplicationSettings m_applicationSettings;
    void run();
    void process(double frame_dt);
    void configure(const ApplicationSettings &);
};
''' + process + run + configure + '''
}
int main() {
    EngineSimApplication app;
    app.configure(ApplicationSettings{});
    assert(app.m_engine.window.style == ysWindow::WindowStyle::Windowed);
    assert(!app.m_applicationSettings.startFullscreen);
    app.run();
    assert(app.actions == 0);
    app.process(1.0);
    assert(app.sim.speed == 1.0);
    assert(app.m_displayAngle == 0);
    app.m_engine.window.active = true;
    app.run();
    assert(app.actions == 5);
    app.process(1.0);
    assert(app.sim.speed == 1.0);
}
''')
            exe = root / 'window-test'
            result = subprocess.run(['g++','-std=c++17',str(harness),'-o',str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
