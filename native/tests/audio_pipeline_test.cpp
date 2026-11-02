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
    double last_seconds = 0;
    bool last_combustion = false;
    bool load(const std::string& script) override {
        events.push_back("load:" + script);
        scripts.push_back(script);
        ready_frames = 0;
        return !fail_load;
    }
    bool advance(double seconds, double rpm, double throttle, bool combustion) override {
        ++advances;
        last_seconds = seconds;
        ready_frames += static_cast<std::size_t>(seconds * 44100.0);
        last_rpm = rpm;
        last_throttle = throttle;
        last_combustion = combustion;
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
    bool restore() noexcept override {
        events.push_back("restore:" + name);
        muted = false;
        return true;
    }
};

class TraceSink final : public ProceduralAudioSink {
public:
    explicit TraceSink(std::vector<std::string>& trace) : events(trace) {}
    std::vector<std::string>& events;
    bool started = false;
    bool fail_queue = false;
    int queues = 0;
    std::vector<std::size_t> packet_sizes;
    std::vector<std::int16_t> last;
    bool queue(const std::int16_t* pcm, std::size_t frames) override {
        events.push_back("queue");
        if (fail_queue) return false;
        ++queues;
        packet_sizes.push_back(frames);
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
    assert(pipeline.stage() == NativeAudioPipeline::Stage::Priming);
    assert(!first->muted && !sink.started && !second->muted);
    assert(source->scripts.size() == 1 && source->scripts[0] == "boxer.mr");
    assert(source->advances == 1 && source->reads == 0);
    assert(source->last_rpm == 2000 && source->last_throttle == 0.4);
    assert(source->last_combustion);
    assert(sink.queues == 0 && sink.last.empty());

    // A 120 Hz UE4SS callback must not generate duplicate PCM from the
    // same 50-ms Lua packet: it would play two copies at double the rate.
    assert(!pipeline.process(a1, t + std::chrono::milliseconds(10), 1.0));
    assert(source->advances == 1 && source->reads == 0 && sink.queues == 0);

    const auto a2 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 2 3200 0.900 1 4 43617241 2 6500");
    assert(a2);
    assert(pipeline.process(a2, t + std::chrono::milliseconds(50), 0.0));
    assert(pipeline.stage() == NativeAudioPipeline::Stage::Playing);
    assert(source->scripts.size() == 1 && source->advances == 2);
    assert(source->last_rpm == 3200 && source->last_combustion);
    assert(sink.queues == 2 && sink.last.size() == 2205 && first->muted); // 60-ms lead + PCM
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
    assert(pipeline.stage() == NativeAudioPipeline::Stage::NoProfile);
    assert(!second->muted && !sink.started);
    assert(source->scripts.size() == 2);

    // Without a verified stock emitter, never play replacement sound.
    emitters.unavailable = true;
    const auto a6 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 6 2100 0.500 1 3 43617241 2 6500");
    assert(a6);
    assert(!pipeline.process(a6, t + std::chrono::milliseconds(250), 1.0));
    assert(pipeline.stage() == NativeAudioPipeline::Stage::NoEmitter);
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
    assert(pipeline.stage() == NativeAudioPipeline::Stage::OutputQueueFailed);
    assert(!first->muted && !sink.started);
    sink.fail_queue = false;

    const auto a12 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 12 2400 0.500 1 3 43617241 2 6500");
    assert(a12 && pipeline.process(a12, t + std::chrono::milliseconds(550), 1.0));
    assert(first->muted);

    // An asynchronous producer's partial first read must be assembled into
    // a complete packet without ever restoring stock mid-drive.
    source->underrun_once = true;
    const auto a13 = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 13 2500 0.500 1 3 43617241 2 6500");
    const auto loads_before_underflow = source->scripts.size();
    assert(a13 && pipeline.process(a13, t + std::chrono::milliseconds(600), 1.0));
    assert(pipeline.stage() == NativeAudioPipeline::Stage::Playing);
    assert(first->muted && sink.started);
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
    assert(pipeline.stage() == NativeAudioPipeline::Stage::NoTelemetry);
    assert(!first->muted && !sink.started);
    const auto loads_before_replay = source->scripts.size();
    assert(!pipeline.process(a14, t + std::chrono::seconds(1), 1.0));
    assert(!pipeline.process(a13, t + std::chrono::seconds(1), 1.0));
    assert(source->scripts.size() == loads_before_replay);
    assert(!first->muted && !sink.started);
    const auto off = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 15 0 0 0 0 43617241 2 6500");
    const auto loads_before_off = source->scripts.size();
    assert(off && !pipeline.process(off, t + std::chrono::seconds(2), 1.0));
    assert(!first->muted && !sink.started);
    // A standing engine is compiled now, once, so its start is heard.
    assert(pipeline.stage() == NativeAudioPipeline::Stage::EngineStopped);
    assert(source->scripts.size() == loads_before_off + 1);
    const auto stillOff = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 16 0 0 0 0 43617241 2 6500");
    assert(!pipeline.process(stillOff, t + std::chrono::milliseconds(2050), 1.0));
    assert(source->scripts.size() == loads_before_off + 1);
    // The starter cranks with the ignition off: the preloaded engine turns
    // unfired, without another compile.
    const auto cranking = parse_game_telemetry(
        "MTES2 A1B2C3D4E5F60708 17 150 1 0 0 43617241 2 6500");
    pipeline.process(cranking, t + std::chrono::milliseconds(2100), 1.0);
    assert(source->scripts.size() == loads_before_off + 1);
    assert(source->last_rpm == 150 && !source->last_combustion);

    // Production callers read gain from MTES4 rather than supplying a
    // constant. Unknown settings must restore the original game emitter.
    std::vector<std::string> volumeEvents;
    EngineAudio volumeEngine(std::make_unique<TraceBackend>(volumeEvents));
    TraceSink volumeSink(volumeEvents);
    GameAudioOutput volumeOutput(volumeEngine, volumeSink);
    Profiles volumeProfiles;
    Emitters volumeEmitters;
    auto volumeEmitter = std::make_shared<TraceEmitter>(volumeEvents, "A-volume");
    volumeEmitters.car_a = volumeEmitter;
    NativeAudioPipeline volumePipeline(volumeEngine, volumeOutput, volumeProfiles, volumeEmitters);
    const auto v1 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 1 2000 0.4 1 3 43617241 2 6500 - 0.6");
    const auto v2 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 2 2000 0.4 1 3 43617241 2 6500 - 0.0");
    const auto v3 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 3 2000 0.4 1 3 43617241 2 6500 - -1");
    assert(v1 && v2 && v3);
    assert(!volumePipeline.process(v1, t));
    assert(volumePipeline.process(v2, t + std::chrono::milliseconds(50)));
    assert(volumeEmitter->muted && volumeSink.started && volumeSink.last.size() == 2205);
    for (auto pcm : volumeSink.last) assert(pcm == 0);
    assert(!volumePipeline.process(v3, t + std::chrono::milliseconds(100)));
    assert(volumePipeline.stage() == NativeAudioPipeline::Stage::InvalidVolume);
    assert(!volumeEmitter->muted && !volumeSink.started);

    // Stage diagnostics distinguish a failed script load from PCM starvation.
    std::vector<std::string> brokenEvents;
    auto brokenBackend = std::make_unique<TraceBackend>(brokenEvents);
    brokenBackend->fail_load = true;
    EngineAudio brokenEngine(std::move(brokenBackend));
    TraceSink brokenSink(brokenEvents);
    GameAudioOutput brokenOutput(brokenEngine, brokenSink);
    Profiles brokenProfiles;
    Emitters brokenEmitters;
    brokenEmitters.car_a = std::make_shared<TraceEmitter>(brokenEvents, "broken");
    NativeAudioPipeline brokenPipeline(brokenEngine, brokenOutput,
        brokenProfiles, brokenEmitters);
    assert(!brokenPipeline.process(v1, t));
    assert(brokenPipeline.stage() == NativeAudioPipeline::Stage::EngineLoadFailed);

    // UE4SS's game-thread 50ms timer can actually run every 67ms on a
    // slower game frame rate. Queuing 2205 samples per 67ms would leave
    // 17ms of XAudio2 silence each tick and make stock/synth stutter.
    std::vector<std::string> slowEvents;
    auto slowBackend = std::make_unique<TraceBackend>(slowEvents);
    auto* slowSource = slowBackend.get();
    EngineAudio slowEngine(std::move(slowBackend));
    TraceSink slowSink(slowEvents);
    GameAudioOutput slowOutput(slowEngine, slowSink);
    Profiles slowProfiles;
    Emitters slowEmitters;
    slowEmitters.car_a = std::make_shared<TraceEmitter>(slowEvents, "slow");
    NativeAudioPipeline slowPipeline(slowEngine, slowOutput,
        slowProfiles, slowEmitters);
    const auto s1 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 1 2400 0.5 1 2 43617241 2 6500 - 1.0");
    const auto s2 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 2 2500 0.5 1 2 43617241 2 6500 - 1.0");
    const auto s3 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 3 2600 0.5 1 2 43617241 2 6500 - 1.0");
    const auto s4 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 4 2600 0.5 1 2 43617241 2 6500 - 1.0");
    assert(s1 && s2 && s3 && s4);
    assert(!slowPipeline.process(s1, t)); // Prime the backend.
    assert(slowPipeline.process(s2, t + std::chrono::milliseconds(67)));
    assert(slowSink.last.size() >= 2900 && slowSink.last.size() <= 3000);
    assert(slowSource->last_seconds >= 0.066);
    assert(slowPipeline.process(s3, t + std::chrono::milliseconds(150)));
    assert(slowSink.last.size() >= 3600 && slowSink.last.size() <= 3700);
    assert(slowPipeline.process(s4, t + std::chrono::milliseconds(260)));
    assert(slowSink.packet_sizes[slowSink.packet_sizes.size() - 2] == 4096);
    assert(slowSink.last.size() == 755); // 110 ms = 4851 samples, not 4096.

    // The Unreal tick can be delayed 150 ms. 4096 samples cover only 93 ms
    // and leave an unavoidable ~57-ms XAudio2 gap. The output must queue
    // *all* 6615 samples, in device-sized blocks, to bridge that interval.
    const auto s5 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 5 2600 0.5 1 2 43617241 2 6500 - 1.0");
    assert(s5);
    const auto priorPackets = slowSink.packet_sizes.size();
    assert(slowPipeline.process(s5, t + std::chrono::milliseconds(410)));
    std::size_t emitted = 0;
    for (std::size_t i = priorPackets; i < slowSink.packet_sizes.size(); ++i) {
        assert(slowSink.packet_sizes[i] <= 4096);
        emitted += slowSink.packet_sizes[i];
    }
    assert(emitted == 6615);
    assert(slowSource->last_seconds >= 0.149);

    // A 200-ms hitch exceeds the bounded 8192-frame audio budget; never
    // overrun the fixed pool or silently submit a larger single block.
    const auto s6 = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 6 2600 0.5 1 2 43617241 2 6500 - 1.0");
    assert(s6);
    const auto beforeHitch = slowSink.packet_sizes.size();
    assert(slowPipeline.process(s6, t + std::chrono::milliseconds(610)));
    assert(slowSink.packet_sizes.size() == beforeHitch + 2);
    assert(slowSink.packet_sizes[beforeHitch] == 4096);
    assert(slowSink.packet_sizes[beforeHitch + 1] == 4096);
    assert(slowSource->last_seconds <= 8192.0 / 44100.0 + 0.001);

    // Direct XAudio2 output has no automatic Unreal background suspension.
    // Leaving/minimizing the game must stop that voice and restore stock
    // ownership rather than play the engine indefinitely on the desktop.
    assert(!slowPipeline.process(s6, t + std::chrono::milliseconds(620), false));
    assert(slowPipeline.stage() == NativeAudioPipeline::Stage::Background);
    assert(!slowSink.started &&
        !std::static_pointer_cast<TraceEmitter>(slowEmitters.car_a)->muted);

    // The real UE4SS native worker is clocked every 20 ms, independently of
    // Unreal/Lua's sometimes-delayed telemetry sequence. Keeping the same
    // fresh telemetry must continue feeding the XAudio2 queue at that pace.
    std::vector<std::string> workerClockEvents;
    auto clockBackend = std::make_unique<TraceBackend>(workerClockEvents);
    auto* clockSource = clockBackend.get();
    EngineAudio clockEngine(std::move(clockBackend));
    TraceSink clockSink(workerClockEvents);
    GameAudioOutput clockOutput(clockEngine, clockSink);
    Profiles clockProfiles;
    Emitters clockEmitters;
    auto clockEmitter = std::make_shared<TraceEmitter>(workerClockEvents, "clock");
    clockEmitters.car_a = clockEmitter;
    NativeAudioPipeline clockPipeline(clockEngine, clockOutput,
        clockProfiles, clockEmitters, NativeAudioPipeline::NominalPacketFrames,
        NativeAudioPipeline::Pacing::WorkerClock);
    const auto clockSample = parse_game_telemetry(
        "MTES4 1234567890ABCDEF 1 2400 0.5 1 2 43617241 2 6500 - 0.8");
    assert(clockSample);
    assert(!clockPipeline.process(clockSample, t)); // Prime one time.
    assert(clockSource->advances == 1 && clockSink.queues == 0);
    assert(!clockPipeline.process(clockSample, t + std::chrono::milliseconds(10)));
    assert(clockSource->advances == 1 && clockSink.queues == 0);
    assert(clockPipeline.process(clockSample, t + std::chrono::milliseconds(25)));
    assert(clockSink.queues == 2 && clockSink.last.size() == 1103);
    assert(clockEmitter->muted && clockSink.started);
    assert(clockPipeline.process(clockSample, t + std::chrono::milliseconds(45)));
    assert(clockSource->advances == 3 && clockSink.queues == 3);
    assert(clockSink.last.size() == 882 && clockSource->last_seconds < 0.021);
    for (int ms : {65, 85, 105, 125, 145}) {
        assert(clockPipeline.process(clockSample, t + std::chrono::milliseconds(ms)));
    }
    assert(clockSink.queues == 8 && clockEmitter->muted);
    // Even with a cached packet still fresh, losing game focus must stop the
    // independent voice, never wait for an Unreal tick or a new sequence.
    assert(!clockPipeline.process(clockSample, t + std::chrono::milliseconds(165), false));
    assert(!clockEmitter->muted && !clockSink.started);
    assert(!clockPipeline.process(clockSample, t + std::chrono::milliseconds(170)));
    assert(clockPipeline.stage() == NativeAudioPipeline::Stage::Priming);
    assert(!clockPipeline.process(clockSample, t + std::chrono::milliseconds(260)));
    assert(clockPipeline.stage() == NativeAudioPipeline::Stage::StalePacket);
    assert(!clockEmitter->muted && !clockSink.started);
}
