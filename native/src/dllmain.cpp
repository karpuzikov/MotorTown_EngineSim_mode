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
#include <chrono>
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

// Fixed log strings keep the in-game failure report readable even when the
// compiler/backend or a platform audio device rejects the replacement.
const wchar_t* audio_stage_name(mtes::NativeAudioPipeline::Stage stage) noexcept {
    using Stage = mtes::NativeAudioPipeline::Stage;
    switch (stage) {
    case Stage::NoTelemetry: return STR("no live telemetry");
    case Stage::StalePacket: return STR("telemetry replay or stale packet");
    case Stage::IgnitionOff: return STR("engine ignition off");
    case Stage::InvalidVolume: return STR("invalid game engine volume");
    case Stage::NoProfile: return STR("no exact engine-asset profile match");
    case Stage::NoEmitter: return STR("no eligible stock engine emitter");
    case Stage::EngineLoadFailed: return STR("Engine Simulator script or assets failed to load");
    case Stage::EngineAdvanceFailed: return STR("Engine Simulator advance failed");
    case Stage::Priming: return STR("Engine Simulator priming PCM");
    case Stage::PcmUnderrun: return STR("Engine Simulator PCM buffer underrun");
    case Stage::PcmSilent: return STR("Engine Simulator PCM buffer silent");
    case Stage::PcmUnavailable: return STR("PCM unavailable or stale");
    case Stage::MutePending: return STR("waiting for Lua stock-mute ACK");
    case Stage::StockMuteFailed: return STR("stock engine mute or restoration failed");
    case Stage::OutputQueueFailed: return STR("XAudio2 PCM queue failed");
    case Stage::OutputStartFailed: return STR("XAudio2 PCM start failed");
    case Stage::UnexpectedFailure: return STR("unexpected audio handoff failure");
    case Stage::Playing: return STR("replacement PCM playing");
    }
    return STR("unknown");
}
}

class MotorTownEngineSimMod final : public RC::CppUserModBase {
public:
    MotorTownEngineSimMod() {
        ModName = STR("MotorTownEngineSim");
        ModVersion = STR("0.3.1-dev");
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
        RC::Output::send<RC::LogLevel::Normal>(
            STR("[MTES] Audio diagnostics v0.3.1 active (stage updates every 5 seconds while driving)\n"));
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
                        STR("[MTES] Engine Simulator PCM stopped: {}; stock cue restoring\n"),
                        audio_stage_name(m_pipeline.stage()));
                }
                m_wasPlaying = audible;
            }
            if (!sample || !sample->state.ignition ||
                !m_profiles.script_for(*sample)) m_emitters.cancel();
            // Only active driving requires diagnosis. Log changes promptly,
            // with a 2-second floor, and repeat persistent faults at 5 s.
            // Game audio remains untouched on every reported failure stage.
            if (sample && sample->state.rpm >= 50) {
                const auto stage = m_pipeline.stage();
                const auto since = now - m_lastStageReport;
                if (!m_stageReported ||
                    (since >= std::chrono::seconds(2) && stage != m_lastStage) ||
                    since >= std::chrono::seconds(5)) {
                    RC::Output::send<RC::LogLevel::Normal>(
                        STR("[MTES] Audio stage: {}\n"), audio_stage_name(stage));
                    m_lastStage = stage;
                    m_lastStageReport = now;
                    m_stageReported = true;
                }
            }
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
    mtes::NativeAudioPipeline::Stage m_lastStage = mtes::NativeAudioPipeline::Stage::NoTelemetry;
    mtes::NativeAudioPipeline::Clock::time_point m_lastStageReport{};
    bool m_stageReported = false;
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
