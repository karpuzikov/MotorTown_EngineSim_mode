#!/usr/bin/env python3
"""Patch the MIT-licensed Ange Yaghi engine-sim master branch for Motor Town telemetry.

Usage: python patch_engine_sim.py C:\\path\\to\\engine-sim
Idempotent; writes a timestamped backup before editing.
"""
from pathlib import Path
import sys
import shutil
import hashlib
from datetime import datetime

INCLUDE_ANCHOR = '#include "../include/engine_sim_application.h"'
FUNCTION_START = 'void EngineSimApplication::processEngineInput() {'
FUNCTION_END = '\n}\n\nvoid EngineSimApplication::renderScene() {'
MARK = '// MTES_BRIDGE_V1'
RUNTIME_MARK = '// MTES_RUNTIME_V1'
# Original processEngineInput body at the supported EngineSim revision 85f7c3b.
ORIGINAL_INPUT_SHA256 = '1912b063d7da3adcb1de660eb095e9f63306a4439552d427cbfa5d6710c0b188'

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
                {"before": '''    settings.WindowWidth = 1920;
    settings.WindowHeight = 1080;''', "after": '''    settings.WindowWidth = 960;
    settings.WindowHeight = 540;'''},
                {"before": '''    if (settings.startFullscreen) {
        m_engine.GetGameWindow()->SetWindowStyle(ysWindow::WindowStyle::Fullscreen);
    }''', "after": '''    // The bridge is a companion window, even when an engine script requests fullscreen.
    m_applicationSettings.startFullscreen = false;
    m_engine.GetGameWindow()->SetWindowStyle(ysWindow::WindowStyle::Windowed);'''},
                {"before": '    m_audioSource->SetVolume(1.0f);',
                 "after": '    m_audioSource->SetVolume(0.0f); // Wait for live Motor Town engine telemetry.'},
                {"before": '''    double speed = 1.0 / 1.0;
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

    m_simulator->setSimulationSpeed(speed);''', "after": '''    // Keep live engine audio at real-time speed; standalone slow motion is disabled.
    const double speed = 1.0;

    if ((m_engine.GetGameWindow()->IsActive() && m_engine.IsKeyDown(ysKey::Code::F1))) {
        m_displayAngle += frame_dt * 1.0f;
    }
    else if ((m_engine.GetGameWindow()->IsActive() && m_engine.IsKeyDown(ysKey::Code::F2))) {
        m_displayAngle -= frame_dt * 1.0f;
    }
    else if ((m_engine.GetGameWindow()->IsActive() && m_engine.ProcessKeyDown(ysKey::Code::F3))) {
        m_displayAngle = 0.0f;
    }

    m_simulator->setSimulationSpeed(speed);'''},
                *[{
                    "before": f'm_engine.ProcessKeyDown(ysKey::Code::{key})',
                    "after": f'(m_engine.GetGameWindow()->IsActive() && m_engine.ProcessKeyDown(ysKey::Code::{key}))',
                } for key in ('Escape', 'Return', 'Tab', 'F', 'Right')],
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
        for edit in entry["edits"]:
            # Apply added edits to installations that already have startup
            # diagnostics, validating every anchor before writing any files.
            if text.count(edit["after"]) == 1:
                continue
            if text.count(edit["before"]) != 1:
                raise RuntimeError(f"Unsupported runtime source layout: {path}. No files changed.")
            text = text.replace(edit["before"], edit["after"], 1)
        if text == raw.decode("utf-8").replace("\r\n", "\n"):
            continue
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

LEGACY_OVERRIDE = r'''
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

OVERRIDE = r'''
    // MTES_BRIDGE_V1: engine control comes only from fresh game telemetry.
    // Motor Town physics are untouched; standalone keyboard controls are disabled.
    if (m_iceEngine == nullptr || m_simulator == nullptr) return;
    MtTelemetry mt;
    const bool connected = readMtTelemetry(mt);
    const bool on = connected && mt.running && mt.rpm >= 50.0;
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
    // Muting also silences coast-down/compression noise while disconnected.
    if (m_audioSource != nullptr) m_audioSource->SetVolume(on ? 1.0f : 0.0f);
    if (m_infoCluster != nullptr) {
        m_infoCluster->setLogMessage(!connected ? "MotorTown: waiting for telemetry"
            : on ? "MotorTown: live engine telemetry" : "MotorTown: engine off / no RPM");
    }
'''


def patch(root: Path) -> Path:
    filename = root / 'src' / 'engine_sim_application.cpp'
    if not filename.is_file():
        raise FileNotFoundError(f"Missing {filename}. Select the source repository root.")
    raw = filename.read_bytes()
    source = raw.decode('utf-8').replace('\r\n', '\n')
    start = source.find(FUNCTION_START)
    end = source.find(FUNCTION_END, start)
    if start < 0 or end < 0:
        raise RuntimeError('Source layout changed; unsupported engine-sim revision.')
    installed = MARK in source
    body = source[start + len(FUNCTION_START):end]
    original_body = body
    if installed:
        if source.count(HEADER) != 1:
            raise RuntimeError('Incomplete or changed telemetry header. No source changes made.')
        if body == OVERRIDE:
            print('Already patched:', filename)
            return filename
        if not body.endswith(LEGACY_OVERRIDE):
            raise RuntimeError('Unknown existing telemetry patch. No source changes made.')
        original_body = body[:-len(LEGACY_OVERRIDE)]
    if hashlib.sha256(original_body.encode('utf-8')).hexdigest() != ORIGINAL_INPUT_SHA256:
        raise RuntimeError('Unsupported or modified Engine Simulator input controls. No source changes made.')
    # Replace the control body so keyboard throttle/ignition cannot run before
    # the first valid packet, during autopilot, or after the game exits.
    source = source[:start + len(FUNCTION_START)] + OVERRIDE + source[end:]
    if not installed:
        source = source[:start] + HEADER + '\n' + source[start:]
    backup = filename.with_name(filename.name + '.before-mtes-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    shutil.copy2(filename, backup)
    newline = '\r\n' if b'\r\n' in raw else '\n'
    filename.write_bytes(source.replace('\n', newline).encode('utf-8'))
    print('Patched:', filename)
    print('Backup:', backup)
    return filename


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python patch_engine_sim.py PATH_TO_ENGINE_SIM_REPO')
    root = Path(sys.argv[1]).expanduser().resolve()
    patch(root)
    patch_runtime(root)
