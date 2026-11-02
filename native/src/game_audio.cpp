#include "game_audio.h"

#include <array>
#include "pcm_block_pool.h"

#include <algorithm>
#include <fstream>

namespace mtes {

GameAudioOutput::GameAudioOutput(EngineAudio& source, ProceduralAudioSink& sink)
    : m_source(source), m_sink(sink) {}

GameAudioOutput::~GameAudioOutput() { stop(); }

void GameAudioOutput::capture(const std::int16_t* pcm, std::size_t frames) {
    if (m_captureFile.empty()) return;
    if (m_recentOutput.empty()) m_recentOutput.resize(20 * 44100);
    for (std::size_t i = 0; i < frames; ++i) {
        m_recentOutput[m_recentNext] = pcm[i];
        m_recentNext = (m_recentNext + 1) % m_recentOutput.size();
    }
    m_recentCount = std::min(m_recentOutput.size(), m_recentCount + frames);
}

void GameAudioOutput::write_capture() noexcept {
    if (m_captureFile.empty() || m_recentCount < 2 * 44100) return;
    try {
        std::ofstream out(m_captureFile, std::ios::binary | std::ios::trunc);
        const auto u32 = [&](std::uint32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); };
        const auto u16 = [&](std::uint16_t v) { out.write(reinterpret_cast<const char*>(&v), 2); };
        const auto bytes = static_cast<std::uint32_t>(m_recentCount * 2);
        out.write("RIFF", 4); u32(36 + bytes); out.write("WAVEfmt ", 8);
        u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16);
        out.write("data", 4); u32(bytes);
        const auto size = m_recentOutput.size();
        const auto start = (m_recentNext + size - m_recentCount) % size;
        for (std::size_t i = 0; i < m_recentCount; ++i)
            out.write(reinterpret_cast<const char*>(&m_recentOutput[(start + i) % size]), 2);
    }
    catch (...) {}
    m_recentCount = 0;
}

void GameAudioOutput::stop() noexcept {
    write_capture();
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
        // A late Engine Simulator block while playing is a short gap in the
        // already queued audio. Stopping cost a stock restore, a new lease
        // and priming: in game 20-40 ms holes several times a second
        // (recording 2026-11-02). Stock engine assets are silenced anyway.
        // Stale telemetry or another vehicle still stops at once.
        if (!m_playing || m_source.render_status() != EngineAudio::RenderStatus::PcmUnderrun)
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
        // Start 60 ms behind real time, so one late worker tick drains
        // this lead instead of the speaker.
        if (!m_playing) {
            static const std::array<std::int16_t, LeadSilenceFrames> lead{};
            if (!m_sink.queue(lead.data(), lead.size())) {
                stop();
                m_status = Status::QueueFailed;
                return false;
            }
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
        capture(scratch, frames);
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
