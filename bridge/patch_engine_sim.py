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
    patch(Path(sys.argv[1]).expanduser().resolve())
