#include "game_audio.h"
#include "pcm_block_pool.h"

#include <algorithm>

namespace mtes {

GameAudioOutput::GameAudioOutput(EngineAudio& source, ProceduralAudioSink& sink)
    : m_source(source), m_sink(sink) {}

GameAudioOutput::~GameAudioOutput() { stop(); }

void GameAudioOutput::stop() noexcept {
    // Stop playback before bringing original sound back. The emitter wrapper
    // is responsible for checking its Unreal object is still valid.
    m_sink.stop();
    // Keep ownership across a transient failure: losing the original gain
    // would otherwise strand this vehicle's engine/exhaust at zero volume.
    if (!m_stock || m_stock->restore()) m_stock.reset();
    m_vehicle.clear();
    m_playing = false;
}

bool GameAudioOutput::submit(const std::string& vehicle,
    std::shared_ptr<StockEngineEmitter> stock, std::int16_t* scratch,
    std::size_t frames, std::chrono::steady_clock::time_point when,
    double engineVolume, const std::function<bool()>& stillEligible) {
    if (m_stock && !m_playing) {
        stop();
        if (m_stock) {
            m_status = Status::StockMuteFailed;
            return false; // previous vehicle's restoration is pending
        }
    }
    if (vehicle.empty() || !stock || !scratch || frames == 0) {
        stop();
        m_status = Status::InvalidInput;
        return false;
    }
    if (m_vehicle != vehicle || m_stock != stock) {
        stop();
        if (m_stock) {
            m_status = Status::StockMuteFailed;
            return false;
        }
    }

    // Validate the PCM's vehicle identity under EngineAudio's render lock.
    // A vehicle switch must never overlay synthesis from the previous car.
    if (m_source.render(scratch, frames, when, engineVolume, vehicle) != frames ||
        !m_source.is_replacing_stock()) {
        stop();
        m_status = Status::PcmUnavailable;
        return false;
    }
    // Simulation and asynchronous PCM production take time. Recheck before
    // requesting stock mute or handing audio to XAudio2.
    if (stillEligible && !stillEligible()) {
        stop();
        m_status = Status::InvalidInput;
        return false;
    }
    try {
        // Do not queue or start a second audio source while a game-thread
        // stock-emitter mute request is still pending acknowledgment.
        if (!stock->prepare()) {
            if (m_playing) stop();
            m_status = Status::MutePending;
            return false;
        }
        // Motor Town can update active audio component volumes on its own
        // ticks. Keep stock engine/exhaust muted without recapturing its
        // original gain; if the target is gone, immediately fail open.
        if (m_playing && (!m_stock || !m_stock->mute())) {
            stop();
            m_status = Status::StockMuteFailed;
            return false;
        }
        // A slow game frame can represent 100-185 ms of simulation. The
        // XAudio2 pool owns fixed-size callback blocks; queue *all* PCM,
        // never truncate the game frame to a single 4096-sample block.
        for (std::size_t offset = 0; offset < frames;) {
            const auto chunk = std::min(frames - offset,
                PcmBlockPool::FramesPerBlock);
            if (!m_sink.queue(scratch + offset, chunk)) {
                stop();
                m_status = Status::QueueFailed;
                return false;
            }
            offset += chunk;
        }
        if (stillEligible && !stillEligible()) {
            stop();
            m_status = Status::InvalidInput;
            return false;
        }
        if (m_playing) {
            m_status = Status::Playing;
            return true;
        }
        m_stock = std::move(stock);
        m_vehicle = vehicle;
        if (!m_stock->mute()) {
            stop();
            m_status = Status::StockMuteFailed;
            return false;
        }
        if (!m_sink.start()) {
            stop();
            m_status = Status::StartFailed;
            return false;
        }
        m_playing = true;
        m_status = Status::Playing;
        return true;
    }
    catch (...) {
        stop();
        m_status = Status::InvalidInput;
        return false;
    }
}

} // namespace mtes
