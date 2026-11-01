#include "audio_worker.h"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <thread>

using namespace mtes;
using namespace std::chrono_literals;

namespace {
template <typename Predicate>
bool eventually(Predicate predicate, std::chrono::milliseconds limit = 1500ms) {
    const auto until = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < until) {
        if (predicate()) return true;
        std::this_thread::sleep_for(5ms);
    }
    return predicate();
}

struct SlowBackend final : EngineBackend {
    explicit SlowBackend(std::thread::id caller,
        std::chrono::milliseconds physicsCost = 70ms)
        : main_thread(caller), cost(physicsCost) {}
    const std::thread::id main_thread;
    const std::chrono::milliseconds cost;
    std::atomic<bool> advanced_off_main{false};
    std::atomic<int> advances{0};
    std::size_t available = 0;

    bool load(const std::string&) override { available = 0; return true; }
    bool advance(double seconds, double, double, int) override {
        advanced_off_main.store(std::this_thread::get_id() != main_thread);
        ++advances;
        std::this_thread::sleep_for(cost);
        // Avoid a fake-backend 1-frame floor/round mismatch with the
        // pipeline's lround() packet size; this test is about ownership.
        available += static_cast<std::size_t>(seconds * 44100) + 2;
        return true;
    }
    std::size_t read(std::int16_t* dst, std::size_t frames) override {
        const auto count = std::min(available, frames);
        std::fill_n(dst, count, std::int16_t{1500});
        available -= count;
        return count;
    }
    void stop() noexcept override { available = 0; }
};

struct Emitter final : StockEngineEmitter {
    std::atomic<bool> muted{false};
    bool mute() override { muted = true; return true; }
    bool restore() noexcept override { muted = false; return true; }
};

struct Sink final : ProceduralAudioSink {
    std::atomic<bool> playing{false};
    std::atomic<int> queues{0};
    bool queue(const std::int16_t*, std::size_t frames) override {
        if (frames == 0) return false;
        ++queues;
        return true;
    }
    bool start() override { playing = true; return true; }
    void stop() noexcept override { playing = false; }
};

struct Profiles final : VehicleProfileLookup {
    std::optional<std::string> script_for(const GameTelemetrySample& sample) override {
        if (sample.vehicle == "CarA") return "boxer.mr";
        return {};
    }
};

struct Emitters final : StockEmitterLookup {
    std::shared_ptr<Emitter> emitter = std::make_shared<Emitter>();
    std::shared_ptr<StockEngineEmitter> stock_for(
        const GameTelemetrySample& sample) override {
        return sample.vehicle == "CarA" ? emitter : nullptr;
    }
};

void packet(const std::filesystem::path& file, int seq,
    const std::string& vehicleHex = "43617241") {
    std::ofstream out(file, std::ios::trunc);
    assert(out);
    out << "MTES4 A1B2C3D4E5F60708 " << seq
        << " 2400 0.4 1 3 " << vehicleHex << " 2 6500 454E47 0.8\n";
    out.close();
    assert(out);
}
} // namespace

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::filesystem::path file{argv[1]};
    auto source = std::make_unique<SlowBackend>(std::this_thread::get_id());
    auto* backend = source.get();
    EngineAudio engine(std::move(source));
    Sink sink;
    GameAudioOutput output(engine, sink);
    Profiles profiles;
    Emitters emitters;
    NativeAudioPipeline pipeline(engine, output, profiles, emitters);
    std::atomic<bool> foreground{true};
    std::atomic<int> cancels{0};
    NativeAudioWorker worker(file, pipeline, [&] { return foreground.load(); },
        [&] { ++cancels; });

    packet(file, 1);
    const auto start = std::chrono::steady_clock::now();
    assert(worker.start());
    assert(std::chrono::steady_clock::now() - start < 40ms);
    assert(eventually([&] { return backend->advanced_off_main.load(); }));

    std::this_thread::sleep_for(110ms);
    packet(file, 2);
    assert(eventually([&] { return worker.playing(); }));
    assert(sink.playing && emitters.emitter->muted && sink.queues > 0);

    // While an existing source plays, minimize during an expensive 70-ms
    // advance. An in-flight old packet must not be queued *after* focus loss.
    const int before_focus_advance = backend->advances;
    const int before_focus_queues = sink.queues;
    packet(file, 3);
    assert(eventually([&] { return backend->advances > before_focus_advance; }));
    foreground = false;
    assert(eventually([&] { return !worker.playing() && !sink.playing &&
        !emitters.emitter->muted; }, 500ms));
    assert(sink.queues == before_focus_queues);
    assert(cancels > 0);

    // The game callback is never invoked here. Focus loss must still stop
    // XAudio2 and release Motor Town's stock engine cue promptly.
    foreground = true;
    packet(file, 4);
    assert(eventually([&] { return worker.stage() ==
        NativeAudioPipeline::Stage::Priming; }));
    std::this_thread::sleep_for(80ms);
    packet(file, 5);
    assert(eventually([&] { return worker.playing(); }));

    // A driver switching cars while the old physical model is still
    // advancing must not start another packet from the previous car.
    const int before_switch_advance = backend->advances;
    const int before_switch_queues = sink.queues;
    packet(file, 6);
    assert(eventually([&] { return backend->advances > before_switch_advance; }));
    packet(file, 7, "43617242"); // CarB has no profile or verified emitter.
    assert(eventually([&] { return !worker.playing() && !sink.playing &&
        !emitters.emitter->muted; }, 500ms));
    assert(sink.queues == before_switch_queues);

    packet(file, 8);
    assert(eventually([&] { return worker.stage() ==
        NativeAudioPipeline::Stage::Priming; }));
    std::this_thread::sleep_for(80ms);
    packet(file, 9);
    assert(eventually([&] { return worker.playing(); }));
    // No further Lua packets: a stale telemetry file cannot keep playing.
    assert(eventually([&] { return !worker.playing() && !sink.playing &&
        !emitters.emitter->muted; }, 900ms));
    assert(worker.stage() == NativeAudioPipeline::Stage::NoTelemetry);

    packet(file, 10);
    assert(eventually([&] { return worker.stage() ==
        NativeAudioPipeline::Stage::Priming; }));
    std::this_thread::sleep_for(80ms);
    packet(file, 11);
    assert(eventually([&] { return worker.playing(); }));
    worker.stop();
    assert(!sink.playing && !emitters.emitter->muted && !worker.playing());
    worker.stop(); // Idempotent and safe when the DLL unloads.

    // Unloading during an expensive simulation step must join before any
    // Engine Simulator or XAudio2 object becomes destructible.
    const int before_shutdown = backend->advances;
    packet(file, 12);
    assert(worker.start());
    assert(eventually([&] { return backend->advances > before_shutdown; }));
    worker.stop();
    assert(!worker.playing() && !sink.playing && !emitters.emitter->muted);

    // An unmodified Lua file remains a fresh packet for 250ms. The native
    // worker must keep producing short PCM blocks from it every 20ms, with
    // no game callback and no further telemetry file writes.
    auto continuousSource = std::make_unique<SlowBackend>(
        std::this_thread::get_id(), 0ms);
    auto* continuousBackend = continuousSource.get();
    EngineAudio continuousEngine(std::move(continuousSource));
    Sink continuousSink;
    GameAudioOutput continuousOutput(continuousEngine, continuousSink);
    Profiles continuousProfiles;
    Emitters continuousEmitters;
    NativeAudioPipeline continuousPipeline(continuousEngine, continuousOutput,
        continuousProfiles, continuousEmitters,
        NativeAudioPipeline::NominalPacketFrames,
        NativeAudioPipeline::Pacing::WorkerClock);
    std::atomic<bool> continuousForeground{true};
    std::atomic<int> continuousCancels{0};
    NativeAudioWorker continuousWorker(file, continuousPipeline,
        [&] { return continuousForeground.load(); },
        [&] { ++continuousCancels; });
    packet(file, 13);
    assert(continuousWorker.start());
    assert(eventually([&] { return continuousWorker.playing(); }));
    const int firstQueueCount = continuousSink.queues.load();
    assert(eventually([&] { return continuousSink.queues >= firstQueueCount + 3; },
        200ms));
    assert(continuousBackend->advances >= firstQueueCount + 3);
    assert(continuousSink.playing && continuousEmitters.emitter->muted);
    continuousForeground = false;
    assert(eventually([&] { return !continuousWorker.playing() &&
        !continuousSink.playing && !continuousEmitters.emitter->muted; }, 500ms));
    assert(continuousCancels > 0);
    continuousWorker.stop();
}
