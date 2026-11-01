#pragma once

#include "game_audio.h"

#include <cstddef>
#include <cstdint>
#include <memory>

namespace mtes {

// Optional in-process Windows PCM output; not wired into the game until
// stock engine-emitter ownership has been verified in Motor Town.
// Does not use an Engine Simulator desktop process or graphics/audio window.
class XAudio2Sink final : public ProceduralAudioSink {
public:
    XAudio2Sink();
    ~XAudio2Sink() override;

    XAudio2Sink(const XAudio2Sink&) = delete;
    XAudio2Sink& operator=(const XAudio2Sink&) = delete;

    bool queue(const std::int16_t* pcm, std::size_t frames) override;
    bool start() override;
    void stop() noexcept override;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace mtes
