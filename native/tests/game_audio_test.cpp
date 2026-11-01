#include "engine_audio.h"
#include "game_audio.h"

#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

using namespace mtes;
using Clock = std::chrono::steady_clock;

class FakeBackend final : public EngineBackend {
public:
    bool underrun = false;
    bool load(const std::string&) override { return true; }
    bool advance(double, double, double, int) override { return true; }
    std::size_t read(std::int16_t* dst, std::size_t frames) override {
        const std::size_t n = underrun ? frames / 2 : frames;
        for (std::size_t i = 0; i < n; ++i) dst[i] = 4096;
        return n;
    }
    void stop() noexcept override {}
};

class FakeEmitter final : public StockEngineEmitter {
public:
    std::vector<std::string>* events = nullptr;
    bool muted = false;
    bool ready = true;
    bool allow_mute = true;
    bool allow_restore = true;
    int restores = 0;
    bool prepare() override {
        if (events) events->push_back("prepare");
        return ready;
    }
    bool mute() override {
        if (events) events->push_back("mute");
        if (!allow_mute) return false;
        muted = true;
        return true;
    }
    bool restore() noexcept override {
        if (events) events->push_back("restore");
        if (!allow_restore) return false;
        muted = false;
        ++restores;
        return true;
    }
};

class FakeSink final : public ProceduralAudioSink {
public:
    std::vector<std::string>* events = nullptr;
    bool allow_queue = true;
    bool allow_start = true;
    bool started = false;
    int starts = 0;
    int stops = 0;
    std::vector<std::int16_t> last;
    bool queue(const std::int16_t* samples, std::size_t frames) override {
        if (events) events->push_back("queue");
        if (!allow_queue) return false;
        last.assign(samples, samples + frames);
        return true;
    }
    bool start() override {
        if (events) events->push_back("start");
        ++starts;
        started = allow_start;
        return started;
    }
    void stop() noexcept override {
        if (events) events->push_back("stop");
        ++stops;
        started = false;
        last.clear();
    }
};

int main() {
    auto backend = std::make_unique<FakeBackend>();
    auto* source = backend.get();
    EngineAudio engine(std::move(backend));
    FakeSink sink;
    GameAudioOutput game(engine, sink);
    auto first = std::make_shared<FakeEmitter>();
    auto second = std::make_shared<FakeEmitter>();
    std::vector<std::string> events;
    sink.events = &events;
    first->events = &events;
    second->events = &events;
    bool unrelated_horn_muted = false;
    std::array<std::int16_t, 16> scratch{};
    const Clock::time_point t{};

    // A valid source is queued before the identified stock engine emitter
    // is muted and played. Other vehicle sounds are outside this gate.
    assert(engine.update("Tuscan", "tuscan.mr", {1800, 0.3, 2, true}, t));
    // Rendering a previous vehicle's synthesized engine over a different
    // stock vehicle is unsafe even if its PCM is otherwise healthy.
    assert(!game.submit("Atlas", second, scratch.data(), scratch.size(), t, 1.0));
    assert(!second->muted && !sink.started);
    events.clear();
    assert(game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 1.0));
    assert((std::vector<std::string>(events.end() - 4, events.end()) ==
        std::vector<std::string>{"prepare", "queue", "mute", "start"}));
    assert(first->muted && !unrelated_horn_muted);
    assert(sink.started && sink.starts == 1 && sink.last.size() == 16);
    assert(sink.last[0] == 4096);
    assert(game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 0.0));
    for (auto sample : sink.last) assert(sample == 0);
    assert(first->muted && sink.starts == 1);

    // The game can rewrite its component multiplier while PCM is playing.
    // Reasserting mute on subsequent packets must not restart playback.
    first->muted = false;
    events.clear();
    assert(game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 1.0));
    assert(first->muted && sink.starts == 1);
    assert((events == std::vector<std::string>{"prepare", "mute", "queue"}));

    // Losing permission to mute during playback is a fail-open stop.
    first->allow_mute = false;
    events.clear();
    assert(!game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 1.0));
    assert((events == std::vector<std::string>{"prepare", "mute", "stop", "restore"}));
    assert(!first->muted && !sink.started);
    first->allow_mute = true;
    assert(game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 1.0));
    assert(sink.starts == 2);

    // Underflow cannot leave the stock engine muted or overlay stale PCM.
    source->underrun = true;
    events.clear();
    assert(!game.submit("Tuscan", first, scratch.data(), scratch.size(), t, 1.0));
    assert((events == std::vector<std::string>{"stop", "restore"}));
    assert(!first->muted && !sink.started && sink.last.empty());
    source->underrun = false;

    // Switching vehicles releases old ownership before touching the new one.
    assert(engine.update("Atlas", "atlas.mr", {950, 0.5, 1, true}, t));
    assert(game.submit("Atlas", second, scratch.data(), scratch.size(), t, 0.8));
    assert(!first->muted && second->muted);
    assert(sink.starts == 3 && !unrelated_horn_muted);

    // Invalid telemetry and a failed backend both restore stock immediately.
    second->allow_restore = false;
    assert(!game.submit("Atlas", second, scratch.data(), scratch.size(),
        t + std::chrono::seconds(1), 1.0));
    assert(second->muted && !sink.started);
    assert(engine.update("Tuscan", "tuscan.mr", {1200, 0.25, 1, true},
        t + std::chrono::seconds(1)));
    assert(!game.submit("Tuscan", first, scratch.data(), scratch.size(),
        t + std::chrono::seconds(1), 1.0));
    assert(!first->muted && !sink.started); // block vehicle switch until restored
    second->allow_restore = true;
    game.stop(); // failed restore must retain ownership and retry
    assert(!second->muted && !sink.started);

    // An asynchronous game-thread mute handshake must be acknowledged before
    // PCM can be queued or a sound source started. A pending ACK is retryable.
    assert(engine.update("Tuscan", "tuscan.mr", {1400, 0.4, 2, true},
        t + std::chrono::seconds(2)));
    first->ready = false;
    events.clear();
    assert(!game.submit("Tuscan", first, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    assert(events.back() == "prepare");
    assert(!sink.started && !first->muted);
    first->ready = true;
    assert(game.submit("Tuscan", first, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    game.stop();

    // A sink that cannot queue playback must never mute the stock engine.
    assert(engine.update("Atlas", "atlas.mr", {950, 0.5, 1, true}, t + std::chrono::seconds(2)));
    sink.allow_queue = false;
    assert(!game.submit("Atlas", second, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    assert(!second->muted && !sink.started);
    sink.allow_queue = true;

    // Failure to start Unreal playback after muting must restore immediately.
    sink.allow_start = false;
    assert(!game.submit("Atlas", second, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    assert(!second->muted && !sink.started);
    sink.allow_start = true;

    // An unresolved or unmutable stock emitter must never allow an overlay.
    assert(!game.submit("Atlas", {}, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    second->allow_mute = false;
    assert(!game.submit("Atlas", second, scratch.data(), scratch.size(),
        t + std::chrono::seconds(2), 1.0));
    assert(!second->muted && !sink.started);
}
