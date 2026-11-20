#include "engine_audio.h"

#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <memory>
#include <limits>
#include <stdexcept>
#include <string>

using namespace mtes;
using Clock = std::chrono::steady_clock;

struct FakeEngine : EngineBackend {
    int loads = 0, stops = 0, advances = 0, reads = 0;
    bool load_ok = true, advance_ok = true;
    bool produce_audio = true;
    bool underrun = false;
    bool underrun_emitted = false;
    bool partial_once = false;
    int final_sample_deficit = 0;
    bool throw_after_partial_write = false;
    bool counting = false; // samples 1, 2, 3...: shows a hole or a repeat
    std::int16_t next_value = 1;
    double last_seconds = 0;
    Clock::time_point ready_after{};
    std::string script;
    bool last_combustion = false;
    double last_rpm = 0;
    double last_throttle = 0;
    double last_game_max_rpm = -1;

    bool load(const std::string &path) override {
        ++loads;
        script = path;
        return load_ok;
    }
    void set_game_max_rpm(double maxRpm) override { last_game_max_rpm = maxRpm; }
    bool advance(double seconds, double rpm, double throttle, bool combustion) override {
        ++advances;
        last_seconds = seconds;
        last_rpm = rpm;
        last_throttle = throttle;
        last_combustion = combustion;
        return advance_ok;
    }
    std::size_t read(std::int16_t *dst, std::size_t requested) override {
        ++reads;
        if (Clock::now() < ready_after) return 0;
        if (throw_after_partial_write) {
            dst[0] = 9000;
            throw std::runtime_error("Audio renderer failed mid-buffer");
        }
        if (!produce_audio) return 0;
        if (underrun && underrun_emitted) return 0;
        if (underrun) underrun_emitted = true;
        const std::size_t count = final_sample_deficit > 0
            ? requested > static_cast<std::size_t>(final_sample_deficit)
                ? requested - static_cast<std::size_t>(final_sample_deficit) : 0
            : underrun || partial_once ? requested / 2 : requested;
        partial_once = false;
        for (std::size_t i = 0; i < count; ++i) dst[i] = counting ? next_value++ : 2048;
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
    // throttle; a running engine fires.
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1500, 0.3, 2, true}, start));
    assert(engine->loads == 1 && engine->advances == 1);
    assert(engine->last_rpm == 1500 && engine->last_throttle == 0.3);
    assert(engine->last_combustion);
    assert(engine->last_game_max_rpm == 0); // unknown unless the telemetry says
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1500, 0.3, 2, true, 2900}, start));
    assert(engine->last_game_max_rpm == 2900); // the backend fits the game's range
    // Without a duration the simulator advances by the time since the last update
    // (at least 5 ms); the pipeline asks for more while it builds the output lead.
    assert(engine->last_seconds == 0.005);
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1500, 0.3, 2, true}, start, 0.07));
    assert(engine->last_seconds == 0.07);
    assert(audio.update("Tuscan_C", "assets/engines/tuscan.mr",
        {1500, 0.3, 2, true}, start, 5.0));
    assert(engine->last_seconds == 8192.0 / 44100.0); // the packet limit
    assert(!audio.is_replacing_stock());
    assert(audio.render(pcm.data(), pcm.size(), start) == 16);
    assert(pcm[0] == 2048 && pcm[15] == 2048);
    assert(audio.is_replacing_stock());

    // The genuine synthesizer renders on another thread. A partial first
    // read followed by the available remainder is a complete PCM packet,
    // not a reason to unmute Motor Town's stock cue and restart XAudio2.
    engine->partial_once = true;
    const int reads_before_partial = engine->reads;
    assert(audio.render(pcm.data(), pcm.size(), start) == pcm.size());
    assert(engine->reads == reads_before_partial + 2);
    assert(audio.is_replacing_stock());

    // The simulator's physics-step rounding can generate 8191 PCM samples
    // for a requested 8192-sample packet. Repeating ONE genuine sample is
    // inaudible; rejecting the whole packet causes an audible stock/synth
    // switch. Never paper over a larger shortfall.
    engine->final_sample_deficit = 1;
    const int reads_before_rounding = engine->reads;
    assert(audio.render(pcm.data(), pcm.size(), start) == pcm.size());
    assert(engine->reads == reads_before_rounding + 1); // No pointless 30-ms wait.
    assert(pcm[14] == 2048 && pcm[15] == 2048);
    assert(audio.is_replacing_stock());
    engine->final_sample_deficit = 2;
    engine->counting = true;
    assert(audio.render(pcm.data(), pcm.size(), start) == 0);
    assert(!audio.is_replacing_stock());
    for (auto sample : pcm) assert(sample == 0);
    // A render that missed its deadline is a delay, not a hole: the 14 samples
    // it did read start the next packet, the stream continues without a gap.
    engine->final_sample_deficit = 0;
    assert(audio.render(pcm.data(), pcm.size(), start) == pcm.size());
    for (std::size_t i = 0; i < pcm.size(); ++i) assert(pcm[i] == static_cast<std::int16_t>(i + 1));
    engine->counting = false;

    // The authored 6.5-kHz V10 simulation can be short by 3-9 output samples
    // when its integer physics steps round at the 8192-sample packet limit.
    // At this packet size only a sub-millisecond tail may be held, not a
    // genuinely late 11+ sample rendering block.
    std::array<std::int16_t, 8192> maxPacket{};
    engine->final_sample_deficit = 9;
    const int reads_before_v10 = engine->reads;
    assert(audio.render(maxPacket.data(), maxPacket.size(), start) == maxPacket.size());
    assert(engine->reads == reads_before_v10 + 1);
    assert(maxPacket[8190] == 2048 && maxPacket[8191] == 2048);
    engine->final_sample_deficit = 11;
    assert(audio.render(maxPacket.data(), maxPacket.size(), start) == 0);
    assert(!audio.is_replacing_stock());
    for (auto sample : maxPacket) assert(sample == 0);
    engine->final_sample_deficit = 0;
    // The 8181 samples it did read lead the next packet, with the rest read fresh.
    assert(audio.render(maxPacket.data(), maxPacket.size(), start) == maxPacket.size());
    assert(audio.is_replacing_stock());

    // A packet is rendered after the simulator advanced through it, so a long
    // one is given longer to arrive than a short one (a fixed 30 ms cut off the
    // 70-100 ms packets that build the output lead).
    engine->ready_after = Clock::now() + std::chrono::milliseconds(60);
    assert(audio.render(maxPacket.data(), maxPacket.size(), start) == maxPacket.size());
    engine->ready_after = Clock::now() + std::chrono::milliseconds(80);
    assert(audio.render(pcm.data(), pcm.size(), start) == 0); // 16 frames: gives up at 30 ms
    engine->ready_after = {};

    // Genuine Engine Simulator synthesizes asynchronously and can need
    // >5ms to finish a packet. On the dedicated native worker, allow 20ms
    // for a ready packet without making Unreal's update callback wait.
    engine->ready_after = Clock::now() + std::chrono::milliseconds(18);
    const auto deferred_start = Clock::now();
    assert(audio.render(pcm.data(), pcm.size(), start) == pcm.size());
    assert(Clock::now() - deferred_start >= std::chrono::milliseconds(15));
    assert(audio.is_replacing_stock());
    engine->ready_after = {};

    // The game's Engine Volume must control replacement PCM, including zero.
    assert(audio.render(pcm.data(), pcm.size(), start, 0.25) == 16);
    assert(pcm[0] == 512 && pcm[15] == 512);
    assert(audio.is_replacing_stock());
    assert(audio.render(pcm.data(), pcm.size(), start, 0.0) == 16);
    for (auto sample : pcm) assert(sample == 0);
    assert(audio.is_replacing_stock()); // intentional mute, not audio failure
    assert(audio.render(pcm.data(), pcm.size(), start,
        std::numeric_limits<double>::quiet_NaN()) == 0);
    assert(!audio.is_replacing_stock());

    // The renderer must preserve the stock sound when telemetry expires.
    pcm.fill(123);
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(1)) == 0);
    assert(!audio.is_replacing_stock());
    for (auto sample : pcm) assert(sample == 0);

    // Switching vehicles discards the previous sound, never overlays it.
    assert(audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {900, 0.8, 0, true}, start + std::chrono::seconds(2)));
    assert(engine->loads == 2 && engine->stops == 1);
    assert(engine->last_combustion);

    // The starter cranks with the ignition still off (in game ~150 RPM):
    // heard unfired, not silent, on the already loaded engine.
    assert(audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {150, 1.0, 0, false}, start + std::chrono::milliseconds(2100)));
    assert(engine->loads == 2 && !engine->last_combustion && engine->last_rpm == 150);
    assert(engine->last_seconds > 0.0999 && engine->last_seconds < 0.1001); // the 100 ms since
    // A standing engine is not advanced.
    assert(!audio.update("Atlas_4x2_Semi_C", "assets/engines/atlas.mr",
        {0, 0, 0, false}, start + std::chrono::milliseconds(2200)));
    assert(engine->script == "assets/engines/atlas.mr");
    assert(!audio.is_replacing_stock());

    // Underflow and silent buffers must fail open: original audio stays on.
    engine->underrun = true;
    pcm.fill(123);
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(2)) == 0);
    for (auto sample : pcm) assert(sample == 0);
    assert(!audio.is_replacing_stock());
    engine->underrun = false;
    engine->produce_audio = false;
    const auto frozen_start = Clock::now();
    assert(audio.render(pcm.data(), pcm.size(), start + std::chrono::seconds(2)) == 0);
    assert(Clock::now() - frozen_start < std::chrono::milliseconds(100));
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
