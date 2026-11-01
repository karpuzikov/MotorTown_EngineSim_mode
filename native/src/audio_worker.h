#pragma once

#include "audio_pipeline.h"

#include <atomic>
#include <filesystem>
#include <functional>
#include <future>
#include <stop_token>
#include <thread>

namespace mtes {

// Owns the potentially slow Engine Simulator update, producer wait and XAudio2
// calls. Unreal's on_update callback may read the atomics but must not call
// NativeAudioPipeline while this worker exists.
class NativeAudioWorker final {
public:
    NativeAudioWorker(std::filesystem::path telemetryFile,
        NativeAudioPipeline& pipeline, std::function<bool()> inForeground,
        std::function<void()> cancelLease);
    ~NativeAudioWorker();

    NativeAudioWorker(const NativeAudioWorker&) = delete;
    NativeAudioWorker& operator=(const NativeAudioWorker&) = delete;

    bool start() noexcept;
    void stop() noexcept;
    bool playing() const noexcept { return m_playing.load(); }
    NativeAudioPipeline::Stage stage() const noexcept { return m_stage.load(); }

private:
    void run(std::stop_token token, std::promise<bool>& ready) noexcept;
    void restore() noexcept;

    GameTelemetryReader m_reader;
    NativeAudioPipeline& m_pipeline;
    std::function<bool()> m_inForeground;
    std::function<void()> m_cancelLease;
    std::jthread m_thread;
    std::atomic<bool> m_alive{false};
    std::atomic<bool> m_playing{false};
    std::atomic<NativeAudioPipeline::Stage> m_stage{
        NativeAudioPipeline::Stage::NoTelemetry};
};

} // namespace mtes
