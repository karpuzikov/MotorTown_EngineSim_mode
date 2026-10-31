#include "audio_pipeline.h"

#include <cmath>
#include <limits>
#include <utility>

namespace mtes {

NativeAudioPipeline::NativeAudioPipeline(EngineAudio& engine,
    GameAudioOutput& output, VehicleProfileLookup& profiles,
    StockEmitterLookup& emitters, std::size_t framesPerPacket)
    : m_engine(engine), m_output(output), m_profiles(profiles), m_emitters(emitters),
      m_pcm(framesPerPacket) {}

NativeAudioPipeline::~NativeAudioPipeline() { stop(); }

void NativeAudioPipeline::silence() noexcept {
    // Restore Motor Town's own engine emitter before unloading a script.
    m_output.stop();
    m_engine.stop();
    m_activeEmitter.reset();
    m_activeVehicle.clear();
    m_activeScript.clear();
    m_loaded = false;
    m_running = false;
}

void NativeAudioPipeline::stop() noexcept {
    if (m_loaded || m_running) silence();
    // Do not clear the session/sequence high-water mark: a temporary missing
    // packet must not cause an older sample to restart a muted engine.
}

bool NativeAudioPipeline::process(const std::optional<GameTelemetrySample>& sample,
    Clock::time_point now) {
    return process(sample, now, sample && sample->engine_volume
        ? *sample->engine_volume : std::numeric_limits<double>::quiet_NaN());
}

bool NativeAudioPipeline::process(const std::optional<GameTelemetrySample>& sample,
    Clock::time_point now, double gameEngineVolume) {
    if (!sample) {
        stop();
        return false;
    }

    // The Lua exporter increments every 50 ms, but the Unreal game callback
    // may run much faster. No sequence may create more than one PCM block.
    if (m_seen && sample->session == m_seenSession) {
        if (sample->sequence < m_seenSequence) {
            silence(); // A replay must not keep engine audio ownership.
            return false;
        }
    }
    const bool duplicate = m_seen && sample->session == m_seenSession &&
        sample->sequence == m_seenSequence;
    // Enforce the same 250-ms freshness window as GameTelemetryReader, even
    // if a future adapter mistakenly passes a cached sample after expiry.
    if (m_seen && (now < m_seenAt ||
        (duplicate && now - m_seenAt > std::chrono::milliseconds(250)))) {
        silence();
        return false;
    }

    try {
        if (!duplicate) {
            m_seenSession = sample->session;
            m_seenSequence = sample->sequence;
            m_seenAt = now;
            m_seen = true;
        }

        // Engine switches restore the old car before any potentially costly
        // script lookup/compile, so the previous vehicle never stays muted.
        if (m_loaded && m_activeVehicle != sample->vehicle) silence();
        if (m_pcm.empty() || !sample->state.ignition ||
            !std::isfinite(gameEngineVolume) ||
            gameEngineVolume < 0 || gameEngineVolume > 1) {
            silence();
            return false;
        }

        const auto script = m_profiles.script_for(*sample);
        const auto stock = m_emitters.stock_for(*sample);
        if (!script || script->empty() || !stock) {
            silence();
            return false;
        }
        if (m_loaded && (*script != m_activeScript || stock != m_activeEmitter))
            silence();
        // Volume and live emitter identity are checked on EVERY frame, but
        // simulation and PCM remain once-per-sequence.
        if (duplicate) return m_running;

        const bool newlyLoaded = !m_loaded;
        if (!m_engine.update(sample->vehicle, *script, sample->state, now)) {
            silence();
            return false;
        }

        m_activeVehicle = sample->vehicle;
        m_activeScript = *script;
        m_activeEmitter = stock;
        m_loaded = true;

        // A new Engine Simulator model has advanced only 5 ms. Give its
        // asynchronous synth thread another packet to fill a 50-ms buffer;
        // leave stock audio untouched during this priming period.
        if (newlyLoaded) return false;

        if (!m_output.submit(sample->vehicle, stock, m_pcm.data(), m_pcm.size(),
                now, gameEngineVolume)) {
            // PCM can legitimately underrun while the simulator warms up.
            // GameAudioOutput already restored stock sound; retain the loaded
            // backend so the next sequence can retry without recompilation.
            m_running = false;
            return false;
        }
        m_running = true;
        return true;
    }
    catch (...) {
        silence();
        return false;
    }
}

} // namespace mtes
