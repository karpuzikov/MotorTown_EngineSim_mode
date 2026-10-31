#include "engine_audio.h"

#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

using namespace mtes;
using Clock = std::chrono::steady_clock;

struct FakeEngine : EngineBackend {
    int loads = 0, stops = 0, advances = 0, reads = 0;
    bool load_ok = true, advance_ok = true;
    bool produce_audio = true;
    bool underrun = false;
    bool throw_after_partial_write = false;
    std::string script;
    int last_gear = -99;
    double last_rpm = 0;
    double last_throttle = 0;

    bool load(const std::string &path) override {
        ++loads;
        script = path;
        return load_ok;
    }
    bool advance(double, double rpm, double throttle, int gear) override {
        ++advances;
        last_rpm = rpm;
        last_throttle = throttle;
        last_gear = gear;
        return advance_ok;
    }
    std::size_t read(std::int16_t *dst, std::size_t requested) override {
        ++reads;
        if (throw_after_partial_write) {
            dst[0] = 9000;
            throw std::runtime_error("Audio renderer failed mid-buffer");
        }
        if (!produce_audio) return 0;
        const std::size_t count = underrun ? requested / 2 : requested;
        for (std::size_t i = 0; i < count; ++i) dst[i] = 2048;
        return count;
    }
    void stop() noexcept override { ++stops; }
};

int main() {
    const Clock::time_point start{};
    auto fake = std::make_unique<FakeEngine>();
    auto *engine = fake.get();
    EngineAudio audio(std::move(fake));
    std::array<std::int16_t, 16> pcm{};

    assert(!audio.is_replacing_stock());
    assert(audio.render(pcm.data(), pcm.size(), start) == 0);
    assert(engine->reads == 0);

    // A running player vehicle activates its exact script and follows RPM,
    // throttle and gear (game neutral 0 maps to Engine Simulator neutral -1).
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1500, 0.3, 2, true}, start));
    assert(engine->loads == 1 && engine->advances == 1);
    assert(engine->last_rpm == 1500 && engine->last_throttle == 0.3);
    assert(engine->last_gear == 1);
    assert(!audio.is_replacing_stock());
    assert(audio.render(pcm.data(), pcm.size(), start) == 16);
    assert(pcm[0] == 2048 && pcm[15] == 2048);
    assert(audio.is_replacing_stock());

    // The renderer must preserve the stock sound when telemetry expires.
    pcm.fill(123);
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(1)) == 0);
    assert(!audio.is_replacing_stock());
    for (auto sample : pcm) assert(sample == 0);

    // Switching vehicles discards the previous sound, never overlays it.
    assert(audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {900, 0.8, 0, true}, start + std::chrono::seconds(2)));
    assert(engine->loads == 2 && engine->stops == 1);
    assert(engine->last_gear == -1);
    assert(engine->script == "assets/engines/atlas.mr");
    assert(!audio.is_replacing_stock());

    // Underflow and silent buffers must fail open: original audio stays on.
    engine->underrun = true;
    pcm.fill(123);
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(2)) == 8);
    for (std::size_t i = 8; i < pcm.size(); ++i) assert(pcm[i] == 0);
    assert(!audio.is_replacing_stock());
    engine->underrun = false;
    engine->produce_audio = false;
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(2)) == 0);
    assert(!audio.is_replacing_stock());

    // Invalid data, engine-off and profile failures must never enable mute.
    assert(!audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {0, 0, 0, false}, start + std::chrono::seconds(3)));
    assert(!audio.is_replacing_stock());
    assert(!audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {-5, 0, 1, true}, start + std::chrono::seconds(3)));
    assert(!audio.is_replacing_stock());
    assert(!audio.update("Unknown_C", "", {1200, 0.1, 1, true},
        start + std::chrono::seconds(4)));
    assert(!audio.is_replacing_stock());

    engine->load_ok = false;
    assert(!audio.update("Broken_C", "broken.mr", {2000, 0.4, 1, true},
        start + std::chrono::seconds(5)));
    assert(!audio.is_replacing_stock());

    engine->load_ok = true;
    engine->throw_after_partial_write = true;
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1700, 0.4, 1, true}, start + std::chrono::seconds(6)));
    pcm.fill(123);
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(6)) == 0);
    for (auto sample : pcm) assert(sample == 0);
    assert(!audio.is_replacing_stock());
}
