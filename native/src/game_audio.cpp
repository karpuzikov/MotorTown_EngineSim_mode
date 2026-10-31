#include "game_audio.h"

namespace mtes {

GameAudioOutput::GameAudioOutput(EngineAudio& source, ProceduralAudioSink& sink)
    : m_source(source), m_sink(sink) {}

GameAudioOutput::~GameAudioOutput() { stop(); }

void GameAudioOutput::stop() noexcept {
    // Stop playback before bringing original sound back. The emitter wrapper
    // is responsible for checking its Unreal object is still valid.
    m_sink.stop();
    if (m_stock) m_stock->restore();
    m_stock.reset();
    m_vehicle.clear();
    m_playing = false;
}

bool GameAudioOutput::submit(const std::string& vehicle,
    std::shared_ptr<StockEngineEmitter> stock, std::int16_t* scratch,
    std::size_t frames, std::chrono::steady_clock::time_point when,
    double engineVolume) {
    if (vehicle.empty() || !stock || !scratch || frames == 0) {
        stop();
        return false;
    }
    if (m_vehicle != vehicle || m_stock != stock) stop();

    // Validate the PCM's vehicle identity under EngineAudio's render lock.
    // A vehicle switch must never overlay synthesis from the previous car.
    if (m_source.render(scratch, frames, when, engineVolume, vehicle) != frames ||
        !m_source.is_replacing_stock()) {
        stop();
        return false;
    }
    try {
        if (!m_sink.queue(scratch, frames)) {
            stop();
            return false;
        }
        if (m_playing) return true;
        m_stock = std::move(stock);
        m_vehicle = vehicle;
        if (!m_stock->mute() || !m_sink.start()) {
            stop();
            return false;
        }
        m_playing = true;
        return true;
    }
    catch (...) {
        stop();
        return false;
    }
}

} // namespace mtes
