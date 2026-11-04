#include "engine_audio.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <thread>

namespace mtes {
namespace {
constexpr auto MaxTelemetryAge = std::chrono::milliseconds(250);

bool valid(const EngineState &s) {
    return engine_turning(s) &&
        std::isfinite(s.throttle) && s.throttle >= 0 && s.throttle <= 1 &&
        s.gear >= -2 && s.gear <= 32;
}
} // namespace

EngineAudio::EngineAudio(std::unique_ptr<EngineBackend> backend)
    : m_backend(std::move(backend)) {
    if (!m_backend) throw std::invalid_argument("Engine backend is required");
}

EngineAudio::~EngineAudio() { stop(); }

void EngineAudio::stop_locked() noexcept {
    m_replacing.store(false);
    if (m_active) m_backend->stop();
    m_active = false;
    m_vehicle.clear();
    m_script.clear();
}

void EngineAudio::stop() noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    stop_locked();
}

bool EngineAudio::load_locked(const std::string &vehicle, const std::string &script) {
    stop_locked();
    try {
        if (!m_backend->load(script)) {
            m_updateStatus.store(UpdateStatus::LoadFailed);
            m_backend->stop();
            return false;
        }
    }
    catch (...) {
        m_updateStatus.store(UpdateStatus::LoadFailed);
        m_backend->stop();
        return false;
    }
    m_active = true;
    m_vehicle = vehicle;
    m_script = script;
    m_advancedSinceLoad = false;
    return true;
}

bool EngineAudio::preload(const std::string &vehicle, const std::string &script) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (vehicle.empty() || script.empty()) return false;
    if (m_active && vehicle == m_vehicle && script == m_script) return true;
    return load_locked(vehicle, script);
}

bool EngineAudio::update(const std::string &vehicle, const std::string &script,
    EngineState state, std::chrono::steady_clock::time_point when) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (vehicle.empty() || script.empty() || !valid(state)) {
        m_updateStatus.store(UpdateStatus::InvalidState);
        stop_locked();
        return false;
    }
    if (!m_active || vehicle != m_vehicle || script != m_script) {
        if (!load_locked(vehicle, script)) return false;
    }
    // A preloaded engine has waited unadvanced: start from this frame, not
    // with seconds of backlog PCM.
    if (!m_advancedSinceLoad) m_lastUpdate = when;
    m_advancedSinceLoad = true;
    const double delta = std::clamp(
        std::chrono::duration<double>(when - m_lastUpdate).count(), 0.005,
        8192.0 / 44100.0); // Match the maximum queued 44.1-kHz PCM packet.
    m_lastUpdate = when;
    try {
        m_backend->set_game_max_rpm(state.maxRpm);
        if (!m_backend->advance(delta, state.rpm, state.throttle, state.ignition)) {
            m_updateStatus.store(UpdateStatus::AdvanceFailed);
            stop_locked();
            return false;
        }
    }
    catch (...) {
        m_updateStatus.store(UpdateStatus::AdvanceFailed);
        stop_locked();
        return false;
    }
    m_updateStatus.store(UpdateStatus::Ready);
    return true;
}

std::size_t EngineAudio::render(std::int16_t *dst, std::size_t frames,
    std::chrono::steady_clock::time_point when, double engineVolume,
    const std::string &expectedVehicle) {
    if (!dst || frames == 0) return 0;
    std::fill_n(dst, frames, 0);
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_active || (!expectedVehicle.empty() && m_vehicle != expectedVehicle) ||
        when < m_lastUpdate || when - m_lastUpdate > MaxTelemetryAge ||
        !std::isfinite(engineVolume) || engineVolume < 0 || engineVolume > 1) {
        m_replacing.store(false);
        m_renderStatus.store(RenderStatus::InvalidState);
        return 0;
    }
    try {
        // The genuine synthesizer fills its output FIFO on a separate
        // thread. An incomplete *first* read is not necessarily an underrun:
        // drain the available pieces, allowing a small, bounded scheduling
        // window for the producer to finish the rest. Never expose any
        // partial packet to XAudio2 if the deadline really does expire.
        // Called exclusively by NativeAudioWorker during live playback, so
        // this bounded wait cannot stall Unreal's game-update callback.
        std::size_t count = 0;
        // The pinned simulator integrates an integer number of physical
        // steps. At low authored frequencies (e.g. 6.5-kHz V10) a packet's
        // sample count can differ by a few 44.1-kHz PCM samples. Bound tail
        // continuity to at most 10 samples (<0.23ms), and to a much smaller
        // fraction for shorter packets; genuine underruns still fail open.
        const auto heldTailLimit = std::clamp(frames / std::size_t{800},
            std::size_t{1}, std::size_t{10});
        const auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(30);
        while (count < frames) {
            if (std::chrono::steady_clock::now() >= deadline) break;
            const auto ready = std::min(m_backend->read(dst + count, frames - count),
                frames - count);
            count += ready;
            // Do not waste 30 ms waiting for a sub-millisecond rounding tail
            // while XAudio2 drains its playback queue.
            if (count == frames || (count > 0 && frames - count <= heldTailLimit) ||
                std::chrono::steady_clock::now() >= deadline)
                break;
            if (ready == 0) {
                std::this_thread::sleep_until(std::min(deadline,
                    std::chrono::steady_clock::now() + std::chrono::milliseconds(1)));
            }
        }
        // Carry only the last genuine sample across a tiny rounding tail;
        // an actual missing producer batch is too large and fails below.
        if (count > 0 && count < frames && frames - count <= heldTailLimit) {
            std::fill(dst + count, dst + frames, dst[count - 1]);
            count = frames;
        }
        // An incomplete or entirely silent buffer must not leak partial
        // replacement sound on top of Motor Town's stock engine emitter.
        if (count != frames ||
            !std::any_of(dst, dst + count, [](std::int16_t sample) { return sample != 0; })) {
            m_renderStatus.store(count != frames ? RenderStatus::PcmUnderrun :
                RenderStatus::PcmSilent);
            std::fill_n(dst, frames, 0);
            m_replacing.store(false);
            return 0;
        }
        // Engine Volume 0 is an intentional in-game mute. Keep ownership of
        // the stock emitter if the unscaled simulator audio was valid.
        for (std::size_t i = 0; i < count; ++i) {
            dst[i] = static_cast<std::int16_t>(std::lround(dst[i] * engineVolume));
        }
        m_replacing.store(true);
        m_renderStatus.store(RenderStatus::Ready);
        return count;
    }
    catch (...) {
        m_renderStatus.store(RenderStatus::InvalidState);
        stop_locked();
        std::fill_n(dst, frames, 0);
        return 0;
    }
}

} // namespace mtes
