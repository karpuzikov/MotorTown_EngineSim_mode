#pragma once

#include "game_audio.h"
#include "game_telemetry.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace mtes {

// The game adapter must resolve to a real packaged Engine Simulator profile.
// Unknown vehicles deliberately remain on their original game audio.
class VehicleProfileLookup {
public:
    virtual ~VehicleProfileLookup() = default;
    virtual std::optional<std::string> script_for(const GameTelemetrySample& sample) = 0;
};

// Return only a positively identified local-vehicle engine emitter, never
// tire, horn, transmission, radio or ambient sound components. Keep wrapper
// identity stable across packets for the same Unreal emitter.
class StockEmitterLookup {
public:
    virtual ~StockEmitterLookup() = default;
    virtual std::shared_ptr<StockEngineEmitter> stock_for(
        const GameTelemetrySample& sample) = 0;
};

// Dedicated-audio-worker coordinator from validated Lua/UE4SS telemetry to
// genuine Engine Simulator PCM and fail-open stock-emitter ownership.
// Nominal 2205 frames = 50 ms of 44.1-kHz mono PCM16; delayed Lua telemetry
// ticks produce larger packets to keep the XAudio2 queue continuously fed.
class NativeAudioPipeline final {
public:
    enum class Pacing { TelemetryPackets, WorkerClock };
    enum class Stage {
        NoTelemetry, Background, StalePacket, EngineStopped, InvalidVolume, NoProfile,
        NoEmitter, EngineLoadFailed, EngineAdvanceFailed, Priming,
        PcmUnderrun, PcmSilent, PcmUnavailable, MutePending,
        StockMuteFailed, OutputQueueFailed, OutputStartFailed,
        UnexpectedFailure, Playing
    };
    using Clock = std::chrono::steady_clock;
    static constexpr std::size_t NominalPacketFrames = 2205;
    static constexpr std::size_t MaxPacketFrames = 8192;

    NativeAudioPipeline(EngineAudio& engine, GameAudioOutput& output,
        VehicleProfileLookup& profiles, StockEmitterLookup& emitters,
        std::size_t framesPerPacket = NominalPacketFrames,
        Pacing pacing = Pacing::TelemetryPackets);
    ~NativeAudioPipeline();

    NativeAudioPipeline(const NativeAudioPipeline&) = delete;
    NativeAudioPipeline& operator=(const NativeAudioPipeline&) = delete;

    bool process(const std::optional<GameTelemetrySample>& sample,
        Clock::time_point now, double gameEngineVolume, bool gameInForeground = true,
        const std::function<bool()>& stillEligible = {});
    // Runtime entry point: trust only the game setting carried by MTES4.
    // MTES2/3 and missing settings always leave stock audio in control.
    bool process(const std::optional<GameTelemetrySample>& sample,
        Clock::time_point now);
    // Native XAudio2 is not owned by Unreal's mixer. Stop it on focus loss.
    bool process(const std::optional<GameTelemetrySample>& sample,
        Clock::time_point now, bool gameInForeground);
    // Recheck focus/identity after slow simulation and PCM rendering.
    bool process(const std::optional<GameTelemetrySample>& sample,
        Clock::time_point now, bool gameInForeground,
        const std::function<bool()>& stillEligible);
    void stop() noexcept;
    Stage stage() const noexcept { return m_stage; }

private:
    void silence() noexcept;
    void release_output() noexcept; // silence() but keeps the engine loaded

    EngineAudio& m_engine;
    GameAudioOutput& m_output;
    VehicleProfileLookup& m_profiles;
    StockEmitterLookup& m_emitters;
    std::vector<std::int16_t> m_pcm;
    bool m_autoPacketDuration = false;
    Pacing m_pacing = Pacing::TelemetryPackets;
    Clock::time_point m_lastAudioTickAt{};
    bool m_hasAudioTick = false;
    std::shared_ptr<StockEngineEmitter> m_activeEmitter;
    std::string m_activeVehicle;
    std::string m_activeScript;
    std::string m_seenSession;
    std::uint64_t m_seenSequence = 0;
    Clock::time_point m_seenAt{};
    bool m_seen = false;
    bool m_loaded = false;
    bool m_running = false;
    Stage m_stage = Stage::NoTelemetry;
};

} // namespace mtes
