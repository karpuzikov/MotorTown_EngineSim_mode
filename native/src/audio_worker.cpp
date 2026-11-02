#include "audio_worker.h"

#include <chrono>
#include <utility>

#ifdef _WIN32
#include <objbase.h>
#endif

namespace mtes {

NativeAudioWorker::NativeAudioWorker(std::filesystem::path telemetryFile,
    NativeAudioPipeline& pipeline, std::function<bool()> inForeground,
    std::function<void()> cancelLease)
    : m_reader(std::move(telemetryFile)), m_pipeline(pipeline),
      m_inForeground(std::move(inForeground)), m_cancelLease(std::move(cancelLease)) {}

NativeAudioWorker::~NativeAudioWorker() { stop(); }

bool NativeAudioWorker::start() noexcept {
    if (m_thread.joinable()) {
        if (!m_alive.load()) m_thread.join();
        else return true;
    }
    try {
        std::promise<bool> ready;
        auto future = ready.get_future();
        m_thread = std::jthread([this, &ready](std::stop_token token) {
            run(token, ready);
        });
        const bool started = future.get();
        if (!started) m_thread.join();
        return started;
    }
    catch (...) {
        restore();
        return false;
    }
}

void NativeAudioWorker::restore() noexcept {
    m_pipeline.stop();
    try { m_cancelLease(); } catch (...) { /* Lua's watchdog also restores. */ }
    m_playing.store(false);
}

void NativeAudioWorker::stop() noexcept {
    if (m_thread.joinable()) {
        m_thread.request_stop();
        m_thread.join(); // Do not unload native/UE4SS objects until it exits.
    }
    restore();
    m_stage.store(NativeAudioPipeline::Stage::NoTelemetry);
}

void NativeAudioWorker::record_drop(NativeAudioPipeline::Stage reason) noexcept {
    m_lastDropStage.store(reason);
    m_dropCounts[static_cast<std::size_t>(reason)].fetch_add(1);
    m_totalDrops.fetch_add(1);
}

void NativeAudioWorker::run(std::stop_token token,
    std::promise<bool>& ready) noexcept {
    using namespace std::chrono_literals;
#ifdef _WIN32
    // COM is per-thread. XAudio2Create on this new thread cannot rely on
    // Motor Town's Unreal thread having initialized the COM apartment.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com)) {
        restore();
        m_stage.store(NativeAudioPipeline::Stage::UnexpectedFailure);
        ready.set_value(false);
        return;
    }
#endif
    m_alive.store(true);
    ready.set_value(true);
    while (!token.stop_requested()) {
        const auto now = NativeAudioPipeline::Clock::now();
        try {
            m_reader.poll(now);
            const auto sample = m_reader.current(now);
            const bool foreground = m_inForeground();
            const bool audible = m_pipeline.process(sample, now, foreground, [&] {
                if (!m_inForeground()) return false;
                const auto checkAt = NativeAudioPipeline::Clock::now();
                m_reader.poll(checkAt);
                const auto fresh = m_reader.current(checkAt);
                // A new gear/RPM/volume can play until the next packet, but a
                // new vehicle, asset or a stopped engine cannot lease old
                // audio. (Volume did: every step of the in-game Engine Volume
                // slider stopped and restarted the engine sound.)
                return fresh && sample && fresh->session == sample->session &&
                    fresh->vehicle == sample->vehicle &&
                    fresh->engine_asset == sample->engine_asset &&
                    engine_turning(fresh->state);
            });
            const auto stage = m_pipeline.stage();
            if (!foreground || !sample || !engine_turning(sample->state) ||
                stage == NativeAudioPipeline::Stage::InvalidVolume ||
                stage == NativeAudioPipeline::Stage::NoProfile ||
                stage == NativeAudioPipeline::Stage::NoEmitter) {
                m_cancelLease();
            }
            m_stage.store(stage);
            if (m_playing.exchange(audible) && !audible) record_drop(stage);
        }
        catch (...) {
            const bool wasPlaying = m_playing.load();
            restore();
            if (wasPlaying) record_drop(NativeAudioPipeline::Stage::UnexpectedFailure);
            m_stage.store(NativeAudioPipeline::Stage::UnexpectedFailure);
        }
        std::this_thread::sleep_until(now + 20ms);
    }
    restore();
#ifdef _WIN32
    CoUninitialize();
#endif
    m_alive.store(false);
}

} // namespace mtes
