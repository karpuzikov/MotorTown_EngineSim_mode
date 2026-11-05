#pragma once

#include "audio_pipeline.h"

#include <array>
#include <atomic>
#include <cstdint>
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
    std::uint64_t drop_count(NativeAudioPipeline::Stage reason) const noexcept {
        return m_dropCounts[static_cast<std::size_t>(reason)].load();
    }
    std::uint64_t total_drops() const noexcept { return m_totalDrops.load(); }
    NativeAudioPipeline::Stage last_drop_stage() const noexcept {
        return m_lastDropStage.load();
    }

private:
    void run(std::stop_token token, std::promise<bool>& ready) noexcept;
    void restore() noexcept;
    void record_drop(NativeAudioPipeline::Stage reason) noexcept;

    GameTelemetryReader m_reader;
    NativeAudioPipeline& m_pipeline;
    std::function<bool()> m_inForeground;
    std::function<void()> m_cancelLease;
    std::jthread m_thread;
    std::atomic<bool> m_alive{false};
    std::atomic<bool> m_playing{false};
    std::atomic<NativeAudioPipeline::Stage> m_stage{
        NativeAudioPipeline::Stage::NoTelemetry};
    static constexpr std::size_t StageCount =
        static_cast<std::size_t>(NativeAudioPipeline::Stage::Playing) + 1;
    std::array<std::atomic<std::uint64_t>, StageCount> m_dropCounts{};
    std::atomic<std::uint64_t> m_totalDrops{0};
    std::atomic<NativeAudioPipeline::Stage> m_lastDropStage{
        NativeAudioPipeline::Stage::NoTelemetry};
};

} // namespace mtes
