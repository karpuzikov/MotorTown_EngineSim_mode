#pragma once

#include "engine_audio.h"
#include "spatial_mix.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace mtes {

// The Unreal adapter must identify only local vehicle engine emitters. It
// owns the original level/playing state and restores it exactly on failure.
// The wrapper must validate UObject lifetimes before touching Unreal objects.
class StockEngineEmitter {
public:
    virtual ~StockEngineEmitter() = default;
    // An asynchronous adapter may request a precise game-thread mute and
    // return false while waiting for acknowledgment. PCM must stay silent.
    virtual bool prepare() { return true; }
    virtual bool mute() = 0;
    // False means restoring a still-owned channel failed temporarily. The
    // game adapter must retain this owner and retry on later game ticks.
    virtual bool restore() noexcept = 0;
};

// queue() must not make PCM audible before start() succeeds; stop() must
// terminate output before stock sound is restored to prevent overlaps.
class ProceduralAudioSink {
public:
    virtual ~ProceduralAudioSink() = default;
    virtual bool queue(const std::int16_t* pcm, std::size_t frames) = 0;
    virtual bool start() = 0;
    virtual void stop() noexcept = 0;
    // Frames queued but not yet played: the producer keeps this near a
    // standing lead (audio_lead.h), so a late tick drains the lead, not the speaker.
    virtual std::size_t queued_frames() const noexcept = 0;
    // Position/loudness of the stock sound this output replaces.
    virtual void set_mix(const SpatialMix&) noexcept {}
};

// Queues any number of frames as blocks the sink's pool can hold.
bool queue_in_blocks(ProceduralAudioSink& sink, const std::int16_t* pcm, std::size_t frames);

// Fail-open handoff: never leave the stock emitter muted without complete
// PCM from the matching vehicle and a started procedural output. Call only
// from one owning game/audio-control thread. This does not itself construct
// Unreal components; that remains an in-game SDK adapter task.
class GameAudioOutput final {
public:
    enum class Status {
        Idle, InvalidInput, PcmUnavailable, MutePending, StockMuteFailed,
        QueueFailed, StartFailed, Playing
    };
    GameAudioOutput(EngineAudio& source, ProceduralAudioSink& sink);
    ~GameAudioOutput();

    GameAudioOutput(const GameAudioOutput&) = delete;
    GameAudioOutput& operator=(const GameAudioOutput&) = delete;

    bool submit(const std::string& vehicle, std::shared_ptr<StockEngineEmitter> stock,
        std::int16_t* scratch, std::size_t frames,
        std::chrono::steady_clock::time_point when, double engineVolume,
        const std::function<bool()>& stillEligible = {});
    void stop() noexcept;
    void set_mix(const SpatialMix& mix) noexcept { m_sink.set_mix(mix); }
    std::size_t queued_frames() const noexcept { return m_sink.queued_frames(); }
    Status status() const noexcept { return m_status; }
    // Diagnostics: the last 20 s of exactly what was queued for playback are
    // written here (mono 44.1 kHz WAV) whenever playback stops, so in-game
    // sound can be compared with the simulator's output.
    void set_capture_file(std::filesystem::path file) { m_captureFile = std::move(file); }

private:
    EngineAudio& m_source;
    ProceduralAudioSink& m_sink;
    std::shared_ptr<StockEngineEmitter> m_stock;
    std::string m_vehicle;
    bool m_playing = false;
    Status m_status = Status::Idle;
    std::filesystem::path m_captureFile;
    std::vector<std::int16_t> m_recentOutput; // ring buffer, 20 s
    std::size_t m_recentNext = 0;
    std::size_t m_recentCount = 0;
    void capture(const std::int16_t* pcm, std::size_t frames);
    void write_capture() noexcept;
};

} // namespace mtes
