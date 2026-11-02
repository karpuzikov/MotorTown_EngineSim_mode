#pragma once

#include "audio_pipeline.h"
#include "engine_audio.h"
#include "game_telemetry.h"
#include "xaudio2_sink.h"

#include <array>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace mtes {

// Which voice plays each traffic vehicle (-1: none free). A vehicle keeps
// the voice it already has, so its engine is not recompiled; vehicles new to
// the list take the voices of vehicles that left it.
inline std::vector<int> assign_traffic_voices(const std::vector<std::string>& voiceVehicles,
    const std::vector<std::string>& trafficVehicles) {
    std::vector<int> assignment(trafficVehicles.size(), -1);
    std::vector<bool> taken(voiceVehicles.size(), false);
    for (std::size_t t = 0; t < trafficVehicles.size(); ++t) {
        for (std::size_t v = 0; v < voiceVehicles.size(); ++v) {
            if (!taken[v] && !trafficVehicles[t].empty() && voiceVehicles[v] == trafficVehicles[t]) {
                assignment[t] = static_cast<int>(v);
                taken[v] = true;
                break;
            }
        }
    }
    const auto stillWanted = [&](const std::string& vehicle) {
        for (const auto& wanted : trafficVehicles) if (wanted == vehicle) return true;
        return false;
    };
    for (std::size_t t = 0; t < trafficVehicles.size(); ++t) {
        if (assignment[t] >= 0) continue;
        for (std::size_t v = 0; v < voiceVehicles.size(); ++v) {
            if (!taken[v] && (voiceVehicles[v].empty() || !stillWanted(voiceVehicles[v]))) {
                assignment[t] = static_cast<int>(v);
                taken[v] = true;
                break;
            }
        }
    }
    return assignment;
}

// Engine Simulator sound for the running engines of OTHER vehicles near the
// camera (traffic, a car left idling), each on its own thread, Engine
// Simulator and XAudio2 voice at its stock 3D mix (one shared thread glitched
// in game once two or three engines played). Stock engine sound is silenced globally,
// so there is no lease. Lua lists the nearest few in
// %TEMP%/MotorTownEngineSim_traffic_telemetry.txt (MTES5 lines).
class TrafficEngineVoices final {
public:
    static constexpr std::size_t MaxVoices = 3; // Lua TRAFFIC_VOICE_LIMIT
    using Clock = std::chrono::steady_clock;

    TrafficEngineVoices(std::filesystem::path telemetryFile, VehicleProfileLookup& profiles,
        std::function<bool()> inForeground);
    ~TrafficEngineVoices();

    TrafficEngineVoices(const TrafficEngineVoices&) = delete;
    TrafficEngineVoices& operator=(const TrafficEngineVoices&) = delete;

    void set_output_volume(double volume) noexcept; // call before start()
    bool start() noexcept;
    void stop() noexcept;
    std::size_t playing_voices() const noexcept { return m_playingVoices.load(); }

private:
    struct Voice {
        EngineAudio engine;
        XAudio2Sink sink;
        std::string vehicle; // voice thread only
        std::string script;
        bool started = false;
        Clock::time_point lastTick{};
        std::vector<std::int16_t> pcm;
        std::mutex targetMutex;
        std::optional<GameTelemetrySample> target; // set by the coordinator
        std::string assignedVehicle;               // coordinator only
        std::atomic<bool> playing{false};
        std::jthread thread;
        Voice();
    };

    std::vector<GameTelemetrySample> read_fresh_traffic() const;
    void assign(std::vector<GameTelemetrySample> traffic) noexcept;
    void run_voice(Voice& voice, std::stop_token token) noexcept;
    void play(Voice& voice, const GameTelemetrySample& sample, Clock::time_point now);
    static void silence(Voice& voice) noexcept;

    std::filesystem::path m_telemetryFile;
    VehicleProfileLookup& m_profiles;
    std::function<bool()> m_inForeground;
    std::array<Voice, MaxVoices> m_voices;
    std::atomic<std::size_t> m_playingVoices{0};
    std::jthread m_thread; // coordinator: reads Lua's list, assigns voices
};

} // namespace mtes
