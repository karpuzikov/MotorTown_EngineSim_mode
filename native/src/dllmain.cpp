// In-process UE4SS module. Reads game telemetry, but does not yet replace audio.
// This must be built with the exact UE4SS SDK compatible with Motor Town.
#include "game_telemetry.h"

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>

#include <cstdlib>
#include <filesystem>
#include <optional>
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
        RC::Output::send<RC::LogLevel::Normal>(
            STR("[MTES] Native initialized; engine audio unchanged\n"));
    }

    auto on_update() -> void override {
        if (!m_ready) return;
        if (!m_updateLogged) {
            RC::Output::send<RC::LogLevel::Normal>(
                STR("[MTES] Native update callback active; checking telemetry\n"));
            m_updateLogged = true;
        }
        const auto now = mtes::GameTelemetryFeed::Clock::now();
        m_telemetry.poll(now);
        auto sample = m_telemetry.current(now);
        if (!sample) {
            if (m_hadTelemetry) {
                RC::Output::send<RC::LogLevel::Normal>(
                    STR("[MTES] Native telemetry lost; engine audio unchanged\n"));
            }
            m_hadTelemetry = false;
            m_lastVehicle.clear();
            m_lastGear = -99;
            m_lastVolume.reset();
            return;
        }
        // Read-only discovery until procedural Unreal playback is verified.
        // Never mute game emitters or start a second sound source here.
        if (!m_hadTelemetry || sample->vehicle != m_lastVehicle ||
            sample->state.gear != m_lastGear ||
            sample->engine_volume != m_lastVolume) {
            RC::Output::send<RC::LogLevel::Normal>(
                STR("[MTES] Native telemetry received: gear {}, RPM {}, throttle {}, engine volume {}\n"),
                sample->state.gear, sample->state.rpm, sample->state.throttle,
                sample->engine_volume.value_or(-1.0));
            m_lastVehicle = sample->vehicle;
            m_lastGear = sample->state.gear;
            m_lastVolume = sample->engine_volume;
        }
        m_hadTelemetry = true;
    }

private:
    mtes::GameTelemetryReader m_telemetry{game_telemetry_path()};
    std::string m_lastVehicle;
    std::optional<double> m_lastVolume;
    int m_lastGear = -99;
    bool m_ready = false;
    bool m_updateLogged = false;
    bool m_hadTelemetry = false;
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
