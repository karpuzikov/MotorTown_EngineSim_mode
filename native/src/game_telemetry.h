#pragma once

#include "engine_audio.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace mtes {

struct GameTelemetrySample {
    std::string session;
    std::uint64_t sequence = 0;
    std::string vehicle;
    EngineState state;
    int engine_type = -1; // -1: unverified engine metadata
    double max_rpm = 0;
};

// Missing or unknown gear is rejected: guessing neutral caused the old bridge
// to synthesize the wrong drivetrain sound.
std::optional<GameTelemetrySample> parse_game_telemetry(std::string_view line);

class GameTelemetryFeed final {
public:
    using Clock = std::chrono::steady_clock;

    bool accept(std::string_view line, Clock::time_point received);
    std::optional<GameTelemetrySample> current(Clock::time_point now) const;

private:
    std::optional<GameTelemetrySample> m_latest;
    Clock::time_point m_received{};
};

// Called by the UE4SS native mod's frame callback; no worker process or
// audio device. Rate-limited so a 120 Hz game does not read the file 120 Hz.
class GameTelemetryReader final {
public:
    explicit GameTelemetryReader(std::filesystem::path file);
    void poll(GameTelemetryFeed::Clock::time_point now);
    std::optional<GameTelemetrySample> current(GameTelemetryFeed::Clock::time_point now) const;

private:
    std::filesystem::path m_file;
    GameTelemetryFeed m_feed;
    std::optional<GameTelemetryFeed::Clock::time_point> m_lastPoll;
};

} // namespace mtes
