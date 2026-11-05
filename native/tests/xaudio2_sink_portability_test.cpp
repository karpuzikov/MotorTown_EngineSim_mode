#include "xaudio2_sink.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <type_traits>

static_assert(std::is_base_of_v<mtes::ProceduralAudioSink, mtes::XAudio2Sink>);

int main() {
    mtes::XAudio2Sink sink;
    std::array<std::int16_t, 2205> samples{};
    assert(!sink.queue(nullptr, samples.size()));
    assert(!sink.queue(samples.data(), 0));
    assert(!sink.queue(samples.data(), samples.size() + 1));
#ifndef _WIN32
    // A non-Windows test must not create an external process or audio device.
    assert(!sink.queue(samples.data(), samples.size()));
    assert(!sink.start());
#endif
    sink.stop();
}
