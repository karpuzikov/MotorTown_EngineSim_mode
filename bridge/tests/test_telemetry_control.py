"""Compile the emitted bridge against the native EngineSim/Win32 boundary."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from test_patch import module as patcher, ORIGINAL_SOURCE


BOUNDARY = r'''
#include <cassert>
#include <string>
struct Ignition { bool m_enabled = true; };
struct Engine {
    Ignition ignition;
    double throttle = 1.0;
    Ignition *getIgnitionModule() { return &ignition; }
    void setSpeedControl(double value) { throttle = value; }
};
struct Transmission {
    int gear = 4;
    double clutch = 1.0;
    void changeGear(int value) { gear = value; }
    void setClutchPressure(double value) { clutch = value; }
};
struct Simulator {
    struct { bool m_enabled = true; } m_starterMotor;
    struct { bool m_enabled = true, m_hold = true; double m_rotationSpeed = 9000; } m_dyno;
    Engine engine;
    Transmission transmission;
    Engine *getEngine() { return &engine; }
    Transmission *getTransmission() { return &transmission; }
};
struct Audio { float volume = 1.0f; void SetVolume(float value) { volume = value; } };
struct Info { std::string text; void setLogMessage(const std::string &value) { text = value; } };
namespace units { double rpm(double value) { return value; } }
struct EngineSimApplication {
    Simulator sim;
    Engine *m_iceEngine = &sim.engine;
    Simulator *m_simulator = &sim;
    Audio audio;
    Audio *m_audioSource = &audio;
    Info info;
    Info *m_infoCluster = &info;
    int keyboardCalls = 0;
    double m_speedSetting = 1.0, m_targetSpeedSetting = 1.0, m_dynoSpeed = 9000;
    void processEngineInput();
    void renderScene();
};
'''

HARNESS = r'''
int main() {
    EngineSimApplication app;
    const bool live = std::getenv("MTES_EXPECT_LIVE") != nullptr;
    app.processEngineInput();
    if (live) {
        assert(app.sim.engine.ignition.m_enabled);
        assert(app.sim.m_dyno.m_enabled && app.sim.m_dyno.m_hold);
        assert(app.sim.m_dyno.m_rotationSpeed == 3500);
        assert(app.sim.engine.throttle == 0.8);
        assert(app.audio.volume > 0);
        assert(app.sim.transmission.gear == -1 && app.sim.transmission.clutch == 0);
        // Losing the file must stop audio on the next frame.
        std::remove((std::string(std::getenv("MTES_TEMP")) + "MotorTownEngineSim_telemetry.txt").c_str());
        app.processEngineInput();
    }
    assert(!app.sim.engine.ignition.m_enabled);
    assert(!app.sim.m_starterMotor.m_enabled);
    assert(!app.sim.m_dyno.m_enabled && !app.sim.m_dyno.m_hold);
    assert(app.sim.m_dyno.m_rotationSpeed == 0);
    assert(app.sim.engine.throttle == 0);
    assert(app.m_speedSetting == 0 && app.m_targetSpeedSetting == 0);
    assert(app.audio.volume == 0);
    assert(app.keyboardCalls == 0);
    assert(!app.info.text.empty());
}
'''


@unittest.skipUnless(shutil.which('g++'), 'Requires a C++17 compiler')
class TelemetryControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='MTES controls ')
        cls.root = Path(cls.temp.name)
        (cls.root / 'src').mkdir()
        app = cls.root / 'src/engine_sim_application.cpp'
        app.write_text(ORIGINAL_SOURCE)
        patcher.patch(cls.root)
        (cls.root / 'windows.h').write_text(r'''
#pragma once
#include <cstdlib>
#include <cstring>
using DWORD = unsigned long;
const int MAX_PATH = 260;
inline DWORD GetTempPathA(DWORD size, char *buffer) {
    const char *path = std::getenv("MTES_TEMP");
    if (!path || std::strlen(path) >= size) return 0;
    std::strcpy(buffer, path);
    return static_cast<DWORD>(std::strlen(path));
}
''')
        source = cls.root / 'control-test.cpp'
        source.write_text(BOUNDARY + app.read_text() + HARNESS)
        cls.exe = cls.root / 'control-test'
        build = subprocess.run(['g++', '-std=c++17', '-D_WIN32', '-I', str(cls.root),
                                str(source), '-o', str(cls.exe)], capture_output=True, text=True)
        if build.returncode:
            cls.temp.cleanup()
            raise AssertionError(build.stdout + build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_packet(self, packet=None, live=False):
        with tempfile.TemporaryDirectory(prefix='MTES packet ') as temp:
            if packet is not None:
                (Path(temp) / 'MotorTownEngineSim_telemetry.txt').write_text(packet)
            env = dict(os.environ, MTES_TEMP=temp + os.sep)
            env.pop('MTES_EXPECT_LIVE', None)
            if live:
                env['MTES_EXPECT_LIVE'] = '1'
            result = subprocess.run([str(self.exe)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_game_telemetry_is_silent_from_the_first_frame(self):
        self.check_packet()

    def test_live_telemetry_ignores_keyboard_and_disconnect_mutes_audio(self):
        self.check_packet(f'MTES1 3500 0.8 1 {int(time.time())}\n', live=True)

    def test_stale_malformed_future_and_ignition_off_packets_stay_silent(self):
        now = int(time.time())
        for packet in [f'MTES1 3500 0.8 1 {now - 60}', 'not telemetry',
                       f'MTES1 3500 0.8 1 {now + 60}', f'MTES1 3500 0.8 0 {now}']:
            with self.subTest(packet=packet):
                self.check_packet(packet)


if __name__ == '__main__':
    unittest.main()
