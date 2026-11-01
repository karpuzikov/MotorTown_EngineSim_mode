#include "engine_audio.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <thread>

namespace mtes {
namespace {
constexpr auto MaxTelemetryAge = std::chrono::milliseconds(250);

bool valid(const EngineState &s) {
    return s.ignition && std::isfinite(s.rpm) && s.rpm >= 50 && s.rpm <= 25000 &&
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

bool EngineAudio::update(const std::string &vehicle, const std::string &script,
    EngineState state, std::chrono::steady_clock::time_point when) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (vehicle.empty() || script.empty() || !valid(state)) {
        m_updateStatus.store(UpdateStatus::InvalidState);
        stop_locked();
        return false;
    }
    if (!m_active || vehicle != m_vehicle || script != m_script) {
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
        m_lastUpdate = when;
    }
    const double delta = std::clamp(
        std::chrono::duration<double>(when - m_lastUpdate).count(), 0.005,
        8192.0 / 44100.0); // Match the maximum queued 44.1-kHz PCM packet.
    m_lastUpdate = when;
    try {
        // Engine Simulator uses -1 for neutral, 0 for first gear, etc.
        // Reverse gears have no direct equivalent in the source simulator.
        if (!m_backend->advance(delta, state.rpm, state.throttle,
                state.gear > 0 ? state.gear - 1 : -1)) {
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
        std::size_t count = 0;
        const auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(5);
        while (count < frames) {
            const auto ready = std::min(m_backend->read(dst + count, frames - count),
                frames - count);
            count += ready;
            if (count == frames || std::chrono::steady_clock::now() >= deadline)
                break;
            if (ready == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
