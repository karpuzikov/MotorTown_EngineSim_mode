#pragma once

#include "engine_audio.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace mtes {

// The Unreal adapter must identify only local vehicle engine emitters. It
// owns the original level/playing state and restores it exactly on failure.
// The wrapper must validate UObject lifetimes before touching Unreal objects.
class StockEngineEmitter {
public:
    virtual ~StockEngineEmitter() = default;
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
};

// Fail-open handoff: never leave the stock emitter muted without complete
// PCM from the matching vehicle and a started procedural output. Call only
// from one owning game/audio-control thread. This does not itself construct
// Unreal components; that remains an in-game SDK adapter task.
class GameAudioOutput final {
public:
    GameAudioOutput(EngineAudio& source, ProceduralAudioSink& sink);
    ~GameAudioOutput();

    GameAudioOutput(const GameAudioOutput&) = delete;
    GameAudioOutput& operator=(const GameAudioOutput&) = delete;

    bool submit(const std::string& vehicle, std::shared_ptr<StockEngineEmitter> stock,
        std::int16_t* scratch, std::size_t frames,
        std::chrono::steady_clock::time_point when, double engineVolume);
    void stop() noexcept;

private:
    EngineAudio& m_source;
    ProceduralAudioSink& m_sink;
    std::shared_ptr<StockEngineEmitter> m_stock;
    std::string m_vehicle;
    bool m_playing = false;
};

} // namespace mtes
