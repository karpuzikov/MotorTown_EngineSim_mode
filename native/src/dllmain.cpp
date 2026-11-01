// In-process Engine Simulator PCM with an explicit game-thread mute lease.
// This must be built with the exact UE4SS SDK compatible with Motor Town.
#include "game_telemetry.h"
#include "audio_pipeline.h"
#include "engine_sim_backend.h"
#include "lua_mute_lease.h"
#include "vehicle_profile.h"
#include "xaudio2_sink.h"

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>

#include <cstdlib>
#include <filesystem>
#include <optional>
#include <string>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace {
std::filesystem::path game_telemetry_path() {
    // Matches the Lua producer inside the same game process; no companion app.
    const char* temp = std::getenv("TMP");
    if (!temp || !*temp) temp = std::getenv("TEMP");
    if (!temp || !*temp) return {};
    return std::filesystem::path(temp) / "MotorTownEngineSim_native_telemetry.txt";
}

std::filesystem::path module_root() {
#ifdef _WIN32
    static int moduleMarker = 0;
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&moduleMarker), &module)) return {};
    std::wstring name(32768, L'\0');
    const DWORD size = GetModuleFileNameW(module, name.data(),
        static_cast<DWORD>(name.size()));
    if (size == 0 || size >= name.size()) return {};
    name.resize(size);
    // .../Mods/MotorTownEngineSim/dlls/main.dll -> mod package root.
    return std::filesystem::path(name).parent_path().parent_path();
#else
    return {};
#endif
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

    ~MotorTownEngineSimMod() override {
        m_pipeline.stop();
        m_emitters.cancel();
    }

    auto on_unreal_init() -> void override {
        m_ready = true;
        m_profilesReady = m_profiles.reload();
        RC::Output::send<RC::LogLevel::Normal>(
            STR("[MTES] Native initialized; engine profiles ready: {}\n"),
            m_profilesReady);
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
        if (m_profilesReady) {
            const bool audible = m_pipeline.process(sample, now);
            if (audible != m_wasPlaying) {
                if (audible) {
                    RC::Output::send<RC::LogLevel::Normal>(
                        STR("[MTES] Engine Simulator PCM active; stock V8 cue leased\n"));
                } else {
                    RC::Output::send<RC::LogLevel::Normal>(
                        STR("[MTES] Engine Simulator PCM stopped; stock cue restoring\n"));
                }
                m_wasPlaying = audible;
            }
            if (!sample || !sample->state.ignition ||
                !m_profiles.script_for(*sample)) m_emitters.cancel();
        }
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
        // The lease allows one verified engine cue only; intake, effects,
        // music, horns and ambient audio are never altered.
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
    mtes::EngineAudio m_engine{mtes::make_engine_sim_backend()};
    mtes::XAudio2Sink m_sink;
    mtes::GameAudioOutput m_output{m_engine, m_sink};
    mtes::ExactVehicleProfiles m_profiles{module_root()};
    mtes::LuaMuteLeaseLookup m_emitters{game_telemetry_path().parent_path()};
    mtes::NativeAudioPipeline m_pipeline{m_engine, m_output, m_profiles, m_emitters};
    std::string m_lastVehicle;
    std::optional<double> m_lastVolume;
    int m_lastGear = -99;
    bool m_ready = false;
    bool m_updateLogged = false;
    bool m_hadTelemetry = false;
    bool m_profilesReady = false;
    bool m_wasPlaying = false;
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
