// In-process UE4SS module. Reads game telemetry, but does not yet replace audio.
// This must be built with the exact UE4SS SDK compatible with Motor Town.
#include "game_telemetry.h"

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>

#include <cstdlib>
#include <filesystem>
#include <string>

namespace {
std::filesystem::path game_telemetry_path() {
    // Matches the Lua producer inside the same game process; no companion app.
    const char* temp = std::getenv("TMP");
    if (!temp || !*temp) temp = std::getenv("TEMP");
    if (!temp || !*temp) return {};
    return std::filesystem::path(temp) / "MotorTownEngineSim_native_telemetry.txt";
}
}

class MotorTownEngineSimMod final : public RC::CppUserModBase {
public:
    MotorTownEngineSimMod() {
        ModName = STR("MotorTownEngineSim");
        ModVersion = STR("0.3.0-dev");
        ModDescription = STR("Native Motor Town engine audio (development only)");
        ModAuthors = STR("karpuzikov and contributors");
    }

    auto on_unreal_init() -> void override {
        m_ready = true;
    }

    auto on_update() -> void override {
        if (!m_ready) return;
        const auto now = mtes::GameTelemetryFeed::Clock::now();
        m_telemetry.poll(now);
        auto sample = m_telemetry.current(now);
        if (!sample) {
            m_lastVehicle.clear();
            m_lastGear = -99;
            return;
        }
        // Read-only discovery until procedural Unreal playback is verified.
        // Never mute game emitters or start a second sound source here.
        if (sample->vehicle != m_lastVehicle || sample->state.gear != m_lastGear) {
            RC::Output::send<RC::LogLevel::Verbose>(
                STR("[MTES] Native game telemetry: gear {}\n"), sample->state.gear);
            m_lastVehicle = sample->vehicle;
            m_lastGear = sample->state.gear;
        }
    }

private:
    mtes::GameTelemetryReader m_telemetry{game_telemetry_path()};
    std::string m_lastVehicle;
    int m_lastGear = -99;
    bool m_ready = false;
};

#if defined(_WIN32)
#define MTES_API extern "C" __declspec(dllexport)
#else
#define MTES_API extern "C" __attribute__((visibility("default")))
#endif

MTES_API RC::CppUserModBase *start_mod() {
    return new MotorTownEngineSimMod();
}

MTES_API void uninstall_mod(RC::CppUserModBase *mod) {
    delete mod;
}
