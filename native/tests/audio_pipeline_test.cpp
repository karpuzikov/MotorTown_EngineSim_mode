#include "audio_pipeline.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

using namespace mtes;
using Clock = std::chrono::steady_clock;

class TraceBackend final : public EngineBackend {
public:
    explicit TraceBackend(std::vector<std::string>& trace) : events(trace) {}
    std::vector<std::string>& events;
    std::vector<std::string> scripts;
    bool fail_load = false;
    bool underrun_once = false;
    std::size_t ready_frames = 0;
    int advances = 0;
    int reads = 0;
    double last_rpm = 0;
    double last_throttle = 0;
    int last_gear = -99;
    bool load(const std::string& script) override {
        events.push_back("load:" + script);
        scripts.push_back(script);
        ready_frames = 0;
        return !fail_load;
    }
    bool advance(double seconds, double rpm, double throttle, int gear) override {
        ++advances;
        ready_frames += static_cast<std::size_t>(seconds * 44100.0);
        last_rpm = rpm;
        last_throttle = throttle;
        last_gear = gear;
        return true;
    }
    std::size_t read(std::int16_t* pcm, std::size_t frames) override {
        ++reads;
        const auto count = std::min(ready_frames, underrun_once ? frames / 2 : frames);
        underrun_once = false;
        for (std::size_t i = 0; i < count; ++i) pcm[i] = 2000;
        ready_frames -= count;
        return count;
    }
    void stop() noexcept override {
        events.push_back("backend-stop");
        ready_frames = 0;
    }
};

class TraceEmitter final : public StockEngineEmitter {
public:
    explicit TraceEmitter(std::vector<std::string>& trace, std::string id)
        : events(trace), name(std::move(id)) {}
    std::vector<std::string>& events;
    std::string name;
    bool muted = false;
    bool mute() override { events.push_back("mute:" + name); muted = true; return true; }
    void restore() noexcept override {
        events.push_back("restore:" + name);
        muted = false;
    }
};

class TraceSink final : public ProceduralAudioSink {
public:
    explicit TraceSink(std::vector<std::string>& trace) : events(trace) {}
    std::vector<std::string>& events;
    bool started = false;
    bool fail_queue = false;
    int queues = 0;
    std::vector<std::int16_t> last;
    bool queue(const std::int16_t* pcm, std::size_t frames) override {
        events.push_back("queue");
        if (fail_queue) return false;
        ++queues;
        last.assign(pcm, pcm + frames);
        return true;
    }
    bool start() override { events.push_back("start"); started = true; return true; }
    void stop() noexcept override { events.push_back("stop"); started = false; last.clear(); }
};

class Profiles final : public VehicleProfileLookup {
public:
    std::optional<std::string> script_for(const GameTelemetrySample& s) override {
        if (s.vehicle == "CarA") return "boxer.mr";
        if (s.vehicle == "CarB") return "v8.mr";
        return std::nullopt;
    }
};

class Emitters final : public StockEmitterLookup {
public:
    std::shared_ptr<StockEngineEmitter> car_a;
    std::shared_ptr<StockEngineEmitter> car_b;
    bool unavailable = false;
    std::shared_ptr<StockEngineEmitter> stock_for(const GameTelemetrySample& s) override {
        if (unavailable) return {};
        if (s.vehicle == "CarA") return car_a;
        if (s.vehicle == "CarB") return car_b;
        return {};
    }
};

int main() {
    std::vector<std::string> events;
    auto backend = std::make_unique<TraceBackend>(events);
    auto* source = backend.get();
    EngineAudio engine(std::move(backend));
    TraceSink sink(events);
    GameAudioOutput output(engine, sink);
    Profiles profiles;
    Emitters emitters;
    auto first = std::make_shared<TraceEmitter>(events, "A");
    auto second = std::make_shared<TraceEmitter>(events, "B");
    emitters.car_a = first;
    emitters.car_b = second;
    NativeAudioPipeline pipeline(engine, output, profiles, emitters);
    const Clock::time_point t{};

    // Full MTES2 packet -> matching script -> real EngineAudio -> PCM sink.
    const auto a1 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 1 2000 0.400 1 3 43617241 2 6500");
    assert(a1);
    // At startup, EngineAudio advances only 5ms. A 50ms read would underflow
    // and restarting that engine each packet would prevent it from warming up.
    assert(!pipeline.process(a1, t, 1.0));
    assert(!first->muted && !sink.started && !second->muted);
    assert(source->scripts.size() == 1 && source->scripts[0] == "boxer.mr");
    assert(source->advances == 1 && source->reads == 0);
    assert(source->last_rpm == 2000 && source->last_throttle == 0.4);
    assert(source->last_gear == 2); // Motor Town third -> Engine Simulator second.
    assert(sink.queues == 0 && sink.last.empty());

    // A 120 Hz UE4SS callback must not generate duplicate PCM from the
    // same 50-ms Lua packet: it would play two copies at double the rate.
    assert(!pipeline.process(a1, t + std::chrono::milliseconds(10), 1.0));
    assert(source->advances == 1 && source->reads == 0 && sink.queues == 0);

    const auto a2 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 2 3200 0.900 1 4 43617241 2 6500");
    assert(a2);
    assert(pipeline.process(a2, t + std::chrono::milliseconds(50), 0.0));
    assert(source->scripts.size() == 1 && source->advances == 2);
    assert(source->last_rpm == 3200 && source->last_gear == 3);
    assert(sink.queues == 1 && sink.last.size() == 2205 && first->muted);
    for (auto v : sink.last) assert(v == 0); // Engine Volume 0 remains silent.

    // On a vehicle change the old stock emitter must be restored BEFORE
    // the simulator starts loading the new physical engine model.
    const auto b1 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 3 1500 0.200 1 1 43617242 4 5800");
    assert(b1);
    events.clear();
    assert(!pipeline.process(b1, t + std::chrono::milliseconds(100), 0.7));
    assert(!first->muted && !second->muted && !sink.started);
    assert(source->scripts.size() == 2 && source->scripts[1] == "v8.mr");
    const auto restored = std::find(events.begin(), events.end(), "restore:A");
    const auto loaded = std::find(events.begin(), events.end(), "load:v8.mr");
    assert(restored != events.end() && loaded != events.end() && restored < loaded);

    const auto b2 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 4 1800 0.500 1 2 43617242 4 5800");
    assert(b2 && pipeline.process(b2, t + std::chrono::milliseconds(150), 0.7));
    assert(second->muted && sink.started);

    // Even a duplicate packet may carry a live settings change: an invalid
    // engine-volume reading must not leave a muted stock engine behind.
    assert(!pipeline.process(b2, t + std::chrono::milliseconds(160), 2.0));
    assert(!second->muted && !sink.started);

    // Unknown vehicle configuration must fail open: no guessed engine.
    const auto unknown = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 5 2000 0.500 1 2 43617258 -1 0");
    assert(unknown);
    assert(!pipeline.process(unknown, t + std::chrono::milliseconds(200), 1.0));
    assert(!second->muted && !sink.started);
    assert(source->scripts.size() == 2);

    // Without a verified stock emitter, never play replacement sound.
    emitters.unavailable = true;
    const auto a6 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 6 2100 0.500 1 3 43617241 2 6500");
    assert(a6);
    assert(!pipeline.process(a6, t + std::chrono::milliseconds(250), 1.0));
    assert(!first->muted && !sink.started && source->scripts.size() == 2);
    emitters.unavailable = false;

    // An invalid volume or a failed sink releases stock audio immediately.
    const auto a7 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 7 2150 0.500 1 3 43617241 2 6500");
    assert(a7 && !pipeline.process(a7, t + std::chrono::milliseconds(300), 0.8));
    const auto a8 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 8 2200 0.500 1 3 43617241 2 6500");
    assert(a8 && pipeline.process(a8, t + std::chrono::milliseconds(350), 0.8));
    assert(first->muted);
    const auto a9 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 9 2250 0.500 1 3 43617241 2 6500");
    assert(a9 && !pipeline.process(a9, t + std::chrono::milliseconds(400), 2.0));
    assert(!first->muted && !sink.started);

    // Reload once after volume invalidation; never unload again merely
    // because the asynchronous PCM ring takes time to fill.
    const auto a10 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 10 2300 0.500 1 3 43617241 2 6500");
    assert(a10 && !pipeline.process(a10, t + std::chrono::milliseconds(450), 0.8));
    sink.fail_queue = true;
    const auto a11 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 11 2350 0.500 1 3 43617241 2 6500");
    assert(a11 && !pipeline.process(a11, t + std::chrono::milliseconds(500), 0.8));
    assert(!first->muted && !sink.started);
    sink.fail_queue = false;

    const auto a12 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 12 2400 0.500 1 3 43617241 2 6500");
    assert(a12 && pipeline.process(a12, t + std::chrono::milliseconds(550), 1.0));
    assert(first->muted);

    // A transient sound-buffer underrun must restore stock immediately but
    // keep the Engine Simulator core warm for the next fresh packet.
    source->underrun_once = true;
    const auto a13 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 13 2500 0.500 1 3 43617241 2 6500");
    const auto loads_before_underflow = source->scripts.size();
    assert(a13 && !pipeline.process(a13, t + std::chrono::milliseconds(600), 1.0));
    assert(!first->muted && !sink.started);
    const auto a14 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 14 2600 0.500 1 3 43617241 2 6500");
    assert(a14 && pipeline.process(a14, t + std::chrono::milliseconds(650), 1.0));
    assert(source->scripts.size() == loads_before_underflow && first->muted);

    // The game adapter may lose its emitter UObject between telemetry
    // packets. Duplicate suppression cannot skip this live safety check.
    emitters.unavailable = true;
    assert(!pipeline.process(a14, t + std::chrono::milliseconds(660), 1.0));
    assert(!first->muted && !sink.started);
    emitters.unavailable = false;

    // Stale/missing telemetry and stopped ignition cannot hold the stock mute.
    assert(!pipeline.process(std::nullopt, t + std::chrono::seconds(1), 1.0));
    assert(!first->muted && !sink.started);
    const auto loads_before_replay = source->scripts.size();
    assert(!pipeline.process(a14, t + std::chrono::seconds(1), 1.0));
    assert(!pipeline.process(a13, t + std::chrono::seconds(1), 1.0));
    assert(source->scripts.size() == loads_before_replay);
    assert(!first->muted && !sink.started);
    const auto off = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 15 0 0 0 0 43617241 2 6500");
    assert(off && !pipeline.process(off, t + std::chrono::seconds(2), 1.0));
    assert(!first->muted && !sink.started);
}
