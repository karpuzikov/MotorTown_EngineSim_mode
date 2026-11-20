#include "traffic_engine_voices.h"
#include "audio_lead.h"
#include "engine_sim_backend.h"
#include "profile_level.h"

#include <algorithm>
#include <cmath>
#include <fstream>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace mtes {

TrafficEngineVoices::Voice::Voice()
    : engine(make_engine_sim_backend()), pcm(NativeAudioPipeline::MaxPacketFrames) {}

TrafficEngineVoices::TrafficEngineVoices(std::filesystem::path telemetryFile,
    VehicleProfileLookup& profiles, std::function<bool()> inForeground)
    : m_telemetryFile(std::move(telemetryFile)), m_profiles(profiles),
      m_inForeground(std::move(inForeground)) {}

TrafficEngineVoices::~TrafficEngineVoices() { stop(); }

void TrafficEngineVoices::set_output_volume(double volume) noexcept {
    for (auto& voice : m_voices) voice.sink.set_output_volume(volume);
}

bool TrafficEngineVoices::start() noexcept {
    if (m_thread.joinable()) return true;
    try {
        for (auto& voice : m_voices) {
            voice.thread = std::jthread([this, &voice](std::stop_token token) {
                run_voice(voice, token);
            });
        }
        m_thread = std::jthread([this](std::stop_token token) {
            using namespace std::chrono_literals;
            while (!token.stop_requested()) {
                const auto now = Clock::now();
                std::vector<GameTelemetrySample> traffic;
                try {
                    if (m_inForeground()) traffic = read_fresh_traffic();
                }
                catch (...) {}
                assign(std::move(traffic), now);
                std::size_t playing = 0;
                for (const auto& voice : m_voices) playing += voice.playing.load() ? 1 : 0;
                m_playingVoices.store(playing);
                std::this_thread::sleep_until(now + 20ms);
            }
        });
        return true;
    }
    catch (...) {
        stop();
        return false;
    }
}

void TrafficEngineVoices::stop() noexcept {
    if (m_thread.joinable()) {
        m_thread.request_stop();
        m_thread.join();
    }
    for (auto& voice : m_voices) {
        if (!voice.thread.joinable()) continue;
        voice.thread.request_stop();
        voice.thread.join();
    }
    m_playingVoices.store(0);
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

void TrafficEngineVoices::assign(std::vector<GameTelemetrySample> traffic,
    Clock::time_point now) noexcept {
    try {
        std::vector<std::string> voiceVehicles, trafficVehicles;
        for (const auto& voice : m_voices) voiceVehicles.push_back(voice.assignedVehicle);
        for (const auto& sample : traffic) trafficVehicles.push_back(sample.vehicle);
        const auto assignment = assign_traffic_voices(voiceVehicles, trafficVehicles);
        std::array<bool, MaxVoices> assigned{};
        for (std::size_t i = 0; i < traffic.size(); ++i) {
            if (assignment[i] < 0) continue;
            auto& voice = m_voices[static_cast<std::size_t>(assignment[i])];
            assigned[static_cast<std::size_t>(assignment[i])] = true;
            voice.assignedVehicle = traffic[i].vehicle;
            voice.lastListed = now;
            std::lock_guard<std::mutex> lock(voice.targetMutex);
            voice.target = std::move(traffic[i]);
        }
        for (std::size_t v = 0; v < MaxVoices; ++v) {
            if (assigned[v]) continue;
            // Not listed this time: the voice keeps playing its last state
            // until the vehicle has been gone for the grace period.
            if (!m_voices[v].assignedVehicle.empty() &&
                !traffic_vehicle_gone(m_voices[v].lastListed, now)) continue;
            m_voices[v].assignedVehicle.clear();
            std::lock_guard<std::mutex> lock(m_voices[v].targetMutex);
            m_voices[v].target.reset();
        }
    }
    catch (...) {}
}

void TrafficEngineVoices::run_voice(Voice& voice, std::stop_token token) noexcept {
    using namespace std::chrono_literals;
#ifdef _WIN32
    // XAudio2Create needs COM on this thread (see NativeAudioWorker).
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
    // Traffic yields to the game and the player's own engine (in game the
    // extra simulators made the game lag).
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
    while (!token.stop_requested()) {
        const auto now = Clock::now();
        try {
            std::optional<GameTelemetrySample> target;
            {
                std::lock_guard<std::mutex> lock(voice.targetMutex);
                target = voice.target;
            }
            if (target) play(voice, *target, now);
            else silence(voice);
        }
        catch (...) {
            silence(voice);
        }
        voice.playing.store(voice.started);
        std::this_thread::sleep_until(now + 20ms);
    }
    silence(voice);
    voice.playing.store(false);
#ifdef _WIN32
    CoUninitialize();
#endif
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
    const auto spec = distant_engine_sound_spec(*script);
    if (voice.vehicle != sample.vehicle || voice.script != spec) silence(voice);
    voice.vehicle = sample.vehicle;
    voice.script = spec;
    // Same pacing as the player's engine: the sound made each tick is what has
    // passed plus a share of what the queue lacks of its standing lead.
    const bool firstTick = voice.lastTick == Clock::time_point{};
    std::size_t frames = 0;
    std::optional<double> advanceSeconds;
    if (!firstTick) {
        auto elapsedFrames = static_cast<std::size_t>(std::lround(std::clamp(
            std::chrono::duration<double>(now - voice.lastTick).count(), 0.005,
            static_cast<double>(voice.pcm.size()) / 44100.0) * 44100.0));
        // Until the first sound is queued, the wait since the tick before was
        // the script compile, not time the sound has to cover.
        // (std::min): Windows.h defines max/min macros unless NOMINMAX is set.
        if (!voice.started) elapsedFrames = (std::min)(elapsedFrames, NativeAudioPipeline::WorkerPeriodFrames);
        frames = frames_for_tick(elapsedFrames, voice.sink.queued_frames(), voice.pcm.size());
        advanceSeconds = static_cast<double>(frames) / 44100.0;
    }
    if (!voice.engine.update(sample.vehicle, spec, sample.state, now, advanceSeconds)) {
        silence(voice);
        return;
    }
    voice.lastTick = now;
    if (firstTick) return; // the simulator fills its first buffer meanwhile
    const auto rendered = voice.engine.render(voice.pcm.data(), frames, now,
        sample.engine_volume.value_or(1.0), sample.vehicle);
    if (rendered != frames) return; // late: the sound it did read leads the next packet
    voice.sink.set_mix(sample.mix.value_or(SpatialMix{}));
    if (!queue_in_blocks(voice.sink, voice.pcm.data(), rendered)) {
        silence(voice);
        return;
    }
    if (!voice.started) voice.started = voice.sink.start();
}

} // namespace mtes
