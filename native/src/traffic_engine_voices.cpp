#include "traffic_engine_voices.h"
#include "engine_sim_backend.h"
#include "pcm_block_pool.h"

#include <algorithm>
#include <cmath>
#include <fstream>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace mtes {

TrafficEngineVoices::Voice::Voice() : engine(make_engine_sim_backend()) {}

TrafficEngineVoices::TrafficEngineVoices(std::filesystem::path telemetryFile,
    VehicleProfileLookup& profiles, std::function<bool()> inForeground)
    : m_telemetryFile(std::move(telemetryFile)), m_profiles(profiles),
      m_inForeground(std::move(inForeground)),
      m_pcm(PcmBlockPool::FramesPerBlock) {}

TrafficEngineVoices::~TrafficEngineVoices() { stop(); }

void TrafficEngineVoices::set_output_volume(double volume) noexcept {
    for (auto& voice : m_voices) voice.sink.set_output_volume(volume);
}

bool TrafficEngineVoices::start() noexcept {
    if (m_thread.joinable()) return true;
    try {
        m_thread = std::jthread([this](std::stop_token token) {
            using namespace std::chrono_literals;
#ifdef _WIN32
            // XAudio2Create needs COM on this thread (see NativeAudioWorker).
            if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
#endif
            while (!token.stop_requested()) {
                const auto now = Clock::now();
                tick(now);
                std::this_thread::sleep_until(now + 20ms);
            }
            for (auto& voice : m_voices) silence(voice);
            m_playingVoices.store(0);
#ifdef _WIN32
            CoUninitialize();
#endif
        });
        return true;
    }
    catch (...) {
        return false;
    }
}

void TrafficEngineVoices::stop() noexcept {
    if (!m_thread.joinable()) return;
    m_thread.request_stop();
    m_thread.join();
}

// Lua rewrites the file every ~50 ms; an older file means Lua stopped.
std::vector<GameTelemetrySample> TrafficEngineVoices::read_fresh_traffic() const {
    std::vector<GameTelemetrySample> traffic;
    std::error_code error;
    const auto modified = std::filesystem::last_write_time(m_telemetryFile, error);
    if (error) return traffic;
    const auto age = decltype(modified)::clock::now() - modified;
    if (age < -std::chrono::milliseconds(500) || age > std::chrono::milliseconds(500))
        return traffic;
    std::ifstream file(m_telemetryFile);
    std::string line;
    while (traffic.size() < MaxVoices && std::getline(file, line)) {
        if (auto sample = parse_game_telemetry(line)) traffic.push_back(std::move(*sample));
    }
    return traffic;
}

void TrafficEngineVoices::silence(Voice& voice) noexcept {
    voice.sink.stop();
    voice.engine.stop();
    voice.vehicle.clear();
    voice.script.clear();
    voice.started = false;
    voice.lastTick = {};
}

void TrafficEngineVoices::play(Voice& voice, const GameTelemetrySample& sample,
    Clock::time_point now) {
    const auto script = m_profiles.script_for(sample);
    if (!script || script->empty()) { // electric motors keep their stock sound
        silence(voice);
        return;
    }
    if (voice.vehicle != sample.vehicle || voice.script != *script) silence(voice);
    voice.vehicle = sample.vehicle;
    voice.script = *script;
    // shortcut: a newly assigned vehicle compiles its engine on this thread
    // (~0.3 s), briefly starving the other traffic voices; give each voice
    // its own thread if that is audible in game.
    if (!voice.engine.update(sample.vehicle, *script, sample.state, now)) {
        silence(voice);
        return;
    }
    const bool firstTick = voice.lastTick == Clock::time_point{};
    const double elapsed = std::chrono::duration<double>(now - voice.lastTick).count();
    voice.lastTick = now;
    if (firstTick) return; // the simulator fills its first buffer meanwhile
    const auto frames = std::clamp<std::size_t>(
        static_cast<std::size_t>(std::lround(elapsed * 44100.0)), 1, m_pcm.size());
    const auto rendered = voice.engine.render(m_pcm.data(), frames, now,
        sample.engine_volume.value_or(1.0), sample.vehicle);
    if (rendered != frames) return; // underrun: a short gap, never partial PCM
    voice.sink.set_mix(sample.mix.value_or(SpatialMix{}));
    if (!voice.sink.queue(m_pcm.data(), rendered)) {
        silence(voice);
        return;
    }
    if (!voice.started) voice.started = voice.sink.start();
}

void TrafficEngineVoices::tick(Clock::time_point now) noexcept {
    try {
        std::vector<GameTelemetrySample> traffic;
        if (m_inForeground()) traffic = read_fresh_traffic();
        std::vector<std::string> voiceVehicles, trafficVehicles;
        for (const auto& voice : m_voices) voiceVehicles.push_back(voice.vehicle);
        for (const auto& sample : traffic) trafficVehicles.push_back(sample.vehicle);
        const auto assignment = assign_traffic_voices(voiceVehicles, trafficVehicles);
        std::array<bool, MaxVoices> playing{};
        for (std::size_t i = 0; i < traffic.size(); ++i) {
            if (assignment[i] < 0) continue;
            auto& voice = m_voices[static_cast<std::size_t>(assignment[i])];
            play(voice, traffic[i], now);
            playing[static_cast<std::size_t>(assignment[i])] = !voice.vehicle.empty();
        }
        std::size_t count = 0;
        for (std::size_t v = 0; v < MaxVoices; ++v) {
            if (!playing[v]) silence(m_voices[v]);
            else ++count;
        }
        m_playingVoices.store(count);
    }
    catch (...) {
        for (auto& voice : m_voices) silence(voice);
        m_playingVoices.store(0);
    }
}

} // namespace mtes
