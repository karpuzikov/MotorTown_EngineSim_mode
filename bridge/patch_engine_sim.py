#!/usr/bin/env python3
"""Patch the MIT-licensed Ange Yaghi engine-sim master branch for Motor Town telemetry.

Usage: python patch_engine_sim.py C:\\path\\to\\engine-sim
Idempotent; writes a timestamped backup before editing.
"""
from pathlib import Path
import sys
import shutil
from datetime import datetime

INCLUDE_ANCHOR = '#include "../include/engine_sim_application.h"'
FUNCTION_START = 'void EngineSimApplication::processEngineInput() {'
FUNCTION_END = '\n}\n\nvoid EngineSimApplication::renderScene() {'
MARK = '// MTES_BRIDGE_V1'
RUNTIME_MARK = '// MTES_RUNTIME_V1'

RUNTIME_HEADER = r'''// MTES_RUNTIME_V1
#pragma once
#include <exception>
#include <fstream>
#include <stdexcept>
#include <string>

inline void mtesRuntimeLog(const std::string &message) {
    // A relative filename also works when the user's Documents path is Unicode.
    std::ofstream log("MotorTownEngineSim_runtime.log", std::ios::app);
    log << message << std::endl;
}
'''

RUNTIME_MAIN_BODY = r'''    std::ofstream("MotorTownEngineSim_runtime.log", std::ios::trunc).close();
    mtesRuntimeLog("MotorTown EngineSim runtime v0.2.7");
    try {
        mtesRuntimeLog("Initializing Engine Simulator");
        // Delta's destructors require explicit teardown and are unsafe after a
        // partial initialization. On failure, report it and let process exit
        // reclaim resources; do not unwind a half-initialized application.
        auto *application = new EngineSimApplication;
        application->initialize((void *)&hInstance, ysContextObject::DeviceAPI::DirectX11);
        mtesRuntimeLog("MTES_STARTUP_READY");
        application->run();
        mtesRuntimeLog("Engine Simulator closed");
        application->destroy();
        delete application;
        return 0;
    }
    catch (const std::exception &error) {
        mtesRuntimeLog(std::string("RUNTIME FAILED: ") + error.what());
        MessageBoxA(nullptr, error.what(), "MotorTown EngineSim startup failed", MB_OK | MB_ICONERROR);
        return 1;
    }
    catch (...) {
        mtesRuntimeLog("RUNTIME FAILED: unknown C++ exception");
        MessageBoxA(nullptr, "Engine Simulator failed. See MotorTownEngineSim_runtime.log.",
            "MotorTown EngineSim startup failed", MB_OK | MB_ICONERROR);
        return 1;
    }'''


def runtime_spec() -> dict:
    """One patch definition shared by Python and the embedded PowerShell installer."""
    include = '#include "../include/engine_sim_application.h"'
    return {
        "marker": RUNTIME_MARK,
        "header_path": "include/mtes_runtime.h",
        "header": RUNTIME_HEADER,
        "patches": [
            {"path": "src/main.cpp", "edits": [
                {"before": include,
                 "after": include + '\n#include "../include/mtes_runtime.h"\n' + RUNTIME_MARK},
                {"before": '''    EngineSimApplication application;
    application.initialize((void *)&hInstance, ysContextObject::DeviceAPI::DirectX11);
    application.run();
    application.destroy();

    return 0;''', "after": RUNTIME_MAIN_BODY},
            ]},
            {"path": "src/engine_sim_application.cpp", "edits": [
                {"before": include,
                 "after": include + '\n#include "../include/mtes_runtime.h"\n' + RUNTIME_MARK},
                {"before": '    m_engine.CreateGameWindow(settings);', "after": '''    mtesRuntimeLog("Creating graphics/audio window; shaders=" + shaderPath);
    const ysError mtesWindowError = m_engine.CreateGameWindow(settings);
    if (mtesWindowError != ysError::None) {
        throw std::runtime_error("Graphics/audio initialization failed (Delta error " +
            std::to_string(static_cast<int>(mtesWindowError)) + "). Shader directory: " + shaderPath);
    }
    mtesRuntimeLog("Graphics/audio window initialized");'''},
                {"before": '    m_assetManager.CompileInterchangeFile((m_assetPath + "/assets").c_str(), 1.0f, true);',
                 "after": '''    mtesRuntimeLog("Loading graphics assets: " + m_assetPath);
    m_assetManager.CompileInterchangeFile((m_assetPath + "/assets").c_str(), 1.0f, true);'''},
                {"before": '    m_assetManager.LoadSceneFile((m_assetPath + "/assets").c_str(), true);',
                 "after": '''    m_assetManager.LoadSceneFile((m_assetPath + "/assets").c_str(), true);
    mtesRuntimeLog("Graphics assets loaded");'''},
                {"before": '    const bool compiled = compiler.compile("../assets/main.mr");',
                 "after": '''    mtesRuntimeLog("Compiling engine script: ../assets/main.mr (details in error_log.log)");
    const bool compiled = compiler.compile("../assets/main.mr");'''},
                {"before": '''#endif /* ATG_ENGINE_SIM_PIRANHA_ENABLED */

    if (vehicle == nullptr) {''', "after": '''#endif /* ATG_ENGINE_SIM_PIRANHA_ENABLED */

    if (engine == nullptr) {
        throw std::runtime_error("The engine script did not create an engine. See error_log.log in build-mtes.");
    }
    mtesRuntimeLog("Engine script loaded");

    if (vehicle == nullptr) {'''},
                {"before": '    m_simulator->startAudioRenderingThread();', "after": '''    mtesRuntimeLog("Starting simulated audio renderer");
    m_simulator->startAudioRenderingThread();
    mtesRuntimeLog("Simulated audio renderer started");'''},
            ]},
        ],
    }


def patch_runtime(root: Path) -> None:
    """Add startup logging and guards without changing the telemetry/physics patch."""
    spec = runtime_spec()
    pending = []
    for entry in spec["patches"]:
        path = root / entry["path"]
        raw = path.read_bytes()
        text = raw.decode("utf-8").replace("\r\n", "\n")
        if spec["marker"] in text:
            if not all(edit["after"] in text for edit in entry["edits"]):
                raise RuntimeError(f"Incomplete or changed runtime patch: {path}")
            continue
        for edit in entry["edits"]:
            if text.count(edit["before"]) != 1:
                raise RuntimeError(f"Unsupported runtime source layout: {path}. No files changed.")
            text = text.replace(edit["before"], edit["after"], 1)
        newline = "\r\n" if b"\r\n" in raw else "\n"
        pending.append((path, text.replace("\n", newline).encode("utf-8")))
    # Validate every source first so an unsupported revision cannot be half-patched.
    for path, data in pending:
        backup = path.with_name(path.name + ".before-mtes-runtime-" + datetime.now().strftime("%Y-%m-%d-%H-%M-%S-%f"))
        shutil.copy2(path, backup)
        path.write_bytes(data)
    (root / spec["header_path"]).write_text(spec["header"], encoding="utf-8")

HEADER = r'''// MTES_BRIDGE_V1
#ifdef _WIN32
#include <windows.h>
#endif
#include <fstream>
#include <ctime>
#include <cmath>

namespace {
struct MtTelemetry {
    double rpm = 0.0;
    double throttle = 0.0;
    bool running = false;
};

// The exporter writes only to the current user's temporary directory.
// Reject stale packets; a stopped game must not leave engine audio running.
bool readMtTelemetry(MtTelemetry &out) {
#ifdef _WIN32
    char directory[MAX_PATH + 1] = {};
    DWORD n = GetTempPathA(MAX_PATH, directory);
    if (n == 0 || n > MAX_PATH) return false;
    std::ifstream in(std::string(directory) + "MotorTownEngineSim_telemetry.txt");
    if (!in) return false;
    std::string signature;
    int enabled = 0;
    long long epoch = 0;
    if (!(in >> signature >> out.rpm >> out.throttle >> enabled >> epoch)) return false;
    if (signature != "MTES1" || !std::isfinite(out.rpm) ||
        !std::isfinite(out.throttle) || out.rpm < 0 || out.rpm > 25000 ||
        out.throttle < 0 || out.throttle > 1 || (enabled != 0 && enabled != 1)) return false;
    const auto now = static_cast<long long>(std::time(nullptr));
    if (epoch > now + 1 || now - epoch > 2) return false;
    out.running = enabled != 0;
    return true;
#else
    return false;
#endif
}
} // anonymous namespace
'''

OVERRIDE = r'''
    // MTES_BRIDGE_V1: slave the audio simulator to Motor Town when telemetry is live.
    // The simulation remains the genuine Engine Simulator combustion/audio engine.
    // Motor Town physics are untouched; this process only follows its crankshaft RPM.
    {
        static bool mtWasConnected = false;
        MtTelemetry mt;
        if (readMtTelemetry(mt)) {
            mtWasConnected = true;
            const bool on = mt.running && mt.rpm >= 50.0;
            m_simulator->getEngine()->getIgnitionModule()->m_enabled = on;
            m_simulator->m_starterMotor.m_enabled = false;
            m_simulator->m_dyno.m_enabled = on;
            m_simulator->m_dyno.m_hold = on;
            m_dynoSpeed = on ? units::rpm(mt.rpm) : 0.0;
            m_simulator->m_dyno.m_rotationSpeed = m_dynoSpeed;
            m_simulator->getTransmission()->changeGear(-1);
            m_simulator->getTransmission()->setClutchPressure(0.0);
            m_speedSetting = m_targetSpeedSetting = on ? mt.throttle : 0.0;
            m_iceEngine->setSpeedControl(m_speedSetting);
        }
        else if (mtWasConnected) {
            // Fail silent when the game closes or telemetry disappears.
            m_simulator->m_dyno.m_enabled = false;
            m_simulator->m_dyno.m_hold = false;
            m_simulator->m_starterMotor.m_enabled = false;
            m_simulator->getEngine()->getIgnitionModule()->m_enabled = false;
            m_speedSetting = m_targetSpeedSetting = 0.0;
            m_iceEngine->setSpeedControl(0.0);
        }
    }
'''


def patch(root: Path) -> Path:
    filename = root / 'src' / 'engine_sim_application.cpp'
    if not filename.is_file():
        raise FileNotFoundError(f"Missing {filename}. Select the source repository root.")
    source = filename.read_text(encoding='utf-8')
    if MARK in source:
        print('Already patched:', filename)
        return filename
    start = source.find(FUNCTION_START)
    end = source.find(FUNCTION_END, start)
    if start < 0 or end < 0:
        raise RuntimeError('Source layout changed; unsupported engine-sim revision.')
    # Insert only at the end of the known method, before its closing brace.
    source = source[:end] + OVERRIDE + source[end:]
    # Place include code directly before the method (valid even with platform macros).
    pos = source.find(FUNCTION_START)
    source = source[:pos] + HEADER + '\n' + source[pos:]
    backup = filename.with_name(filename.name + '.before-mtes-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    shutil.copy2(filename, backup)
    filename.write_text(source, encoding='utf-8')
    print('Patched:', filename)
    print('Backup:', backup)
    return filename


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python patch_engine_sim.py PATH_TO_ENGINE_SIM_REPO')
    root = Path(sys.argv[1]).expanduser().resolve()
    patch(root)
    patch_runtime(root)
