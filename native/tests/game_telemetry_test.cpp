#include "game_telemetry.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>

using namespace mtes;
using Clock = std::chrono::steady_clock;

int main(int argc, char **argv) {
    assert(argc == 2);
    const auto start = Clock::time_point{};
    GameTelemetryFeed feed;
    constexpr auto first = "MTES2 AABBCCDDEEFF0011 1 2400.000 0.8000 1 3 54757363616E5F43 2 2900.000";
    assert(feed.accept(first, start));
    auto sample = feed.current(start);
    assert(sample.has_value());
    assert(sample->vehicle == "Tuscan_C");
    assert(sample->state.rpm == 2400.0);
    assert(sample->state.throttle == 0.8);
    assert(sample->state.ignition && sample->state.gear == 3);
    assert(sample->engine_type == 2 && sample->max_rpm == 2900.0);
    assert(sample->engine_asset.empty()); // Original MTES2 packets stay valid.

    // MTES3 adds a stable engine-data asset identity rather than guessing a
    // script from the vehicle's transient actor instance name or RPM limit.
    constexpr auto engineData = "4D545F456E67696E6544617461202F47616D652F456E67696E65732F426F7865722E426F786572";
    const auto assetPacket = std::string("MTES3 AABBCCDDEEFF0011 2 2400 0.8 1 3 ") +
        "54757363616E5F43 2 2900 " + engineData;
    const auto stable = parse_game_telemetry(assetPacket);
    assert(stable && stable->vehicle == "Tuscan_C");
    assert(stable->engine_asset == "MT_EngineData /Game/Engines/Boxer.Boxer");
    const auto missingAsset = parse_game_telemetry(
        "MTES3 AABBCCDDEEFF0011 2 2400 0.8 1 3 54757363616E5F43 -1 0 -");
    assert(missingAsset && missingAsset->engine_asset.empty());
    assert(!parse_game_telemetry(
        "MTES3 AABBCCDDEEFF0011 2 2400 0.8 1 3 54757363616E5F43 2 2900 0Z"));
    for (const std::string controlHex : {"01", "0B", "0C", "7F"}) {
        assert(!parse_game_telemetry(
            "MTES3 AABBCCDDEEFF0011 2 2400 0.8 1 3 54757363616E5F43 2 2900 " +
            controlHex));
    }
    assert(!parse_game_telemetry(
        "MTES3 AABBCCDDEEFF0011 2 2400 0.8 1 3 54757363616E5F43 2 2900"));
    assert(!parse_game_telemetry(
        "MTES2 AABBCCDDEEFF0011 2 2400 0.8 1 3 54757363616E5F43 2 2900 " +
        std::string(engineData)));

    // Re-reading an unchanged file cannot artificially refresh stale game data.
    assert(!feed.accept(first, start + std::chrono::milliseconds(200)));
    assert(!feed.current(start + std::chrono::milliseconds(251)).has_value());

    // A new sample restores telemetry without a restart. A new vehicle is not
    // confused with the previous vehicle just because its gear/RPM match.
    assert(feed.accept("MTES2 AABBCCDDEEFF0011 2 2400.000 0.8000 1 3 41746C61735F43 -1 0.000",
        start + std::chrono::milliseconds(300)));
    assert(feed.current(start + std::chrono::milliseconds(301))->vehicle == "Atlas_C");

    // Incomplete, corrupt, unknown-gear and impossible values never authorize
    // replacement. A partial write must not clear a still-fresh valid sample.
    for (const std::string bad : {
            "MTES2 AABBCCDDEEFF0011 3 1000.0 0.1 1 -99 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 3 nan 0.1 1 2 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 3 1000 1.1 1 2 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 3 1000 0.1 2 2 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 3 1000 0.1 1 2 0G -1 0.0",
            "MTES2 AABBCCDDEEFF0011 3 1000 0.1 1 2 54757363616E5F43 -1",
            "MTES2 AABBCCDDEEFF0011 3 1000 0.1 1 2 54757363616E5F43 -1 0.0 extra",
            "MTES2 AABBCCDDEEFF0011 -1 1000 0.1 1 2 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 +3 1000 0.1 1 2 54757363616E5F43 -1 0.0",
            "MTES2 AABBCCDDEEFF0011 18446744073709551616 1000 0.1 1 2 54757363616E5F43 -1 0.0",
            "MTES2 NOTHEX 3 1000 0.1 1 2 54757363616E5F43 -1 0.0",
            "MTES1 1000 0.1 1 1234",
        }) {
        assert(!feed.accept(bad, start + std::chrono::milliseconds(302)));
    }
    assert(feed.current(start + std::chrono::milliseconds(310))->vehicle == "Atlas_C");
    assert(!feed.current(start + std::chrono::milliseconds(299)).has_value());

    // Lua can hot-reload while the DLL remains resident. A new producer
    // session can restart its sequence at 1, but the same session cannot.
    assert(feed.accept("MTES2 1122334455667788 1 1100 0.4 1 2 54757363616E5F43 -1 0",
        start + std::chrono::milliseconds(320)));
    assert(feed.current(start + std::chrono::milliseconds(320))->state.gear == 2);
    assert(!feed.accept("MTES2 1122334455667788 1 900 0.4 1 1 54757363616E5F43 -1 0",
        start + std::chrono::milliseconds(321)));

    // Exercise the actual file boundary used by the in-game Lua producer and
    // the UE4SS DLL. A reread of the same sequence cannot refresh audio.
    const std::filesystem::path path(argv[1]);
    auto write = [&path](std::string_view packet) {
        std::ofstream file(path, std::ios::trunc);
        file << packet;
    };
    GameTelemetryReader reader(path);
    write(first);
    reader.poll(start);
    assert(reader.current(start)->state.gear == 3);
    write("MTES2 AABBCCDDEEFF0011 2 900.000 0.2500 1 4 41746C61735F43 -1 0.000");
    reader.poll(start + std::chrono::milliseconds(10));
    assert(reader.current(start + std::chrono::milliseconds(10))->state.gear == 3);
    reader.poll(start + std::chrono::milliseconds(50));
    assert(reader.current(start + std::chrono::milliseconds(50))->state.gear == 4);
    write("MTES2 AABBCCDDEEFF0011 3 1000.000"); // interrupted producer write
    reader.poll(start + std::chrono::milliseconds(100));
    assert(reader.current(start + std::chrono::milliseconds(100))->state.gear == 4);
    assert(!reader.current(start + std::chrono::milliseconds(301)));

    // A leftover file from the previous game run is not fresh telemetry,
    // even if it contains a perfectly valid packet and a new DLL loads.
    write(first);
    std::filesystem::last_write_time(path,
        std::filesystem::file_time_type::clock::now() - std::chrono::seconds(5));
    GameTelemetryReader restarted(path);
    restarted.poll(start);
    assert(!restarted.current(start));

    // Age is measured from the producer's file write, not the moment the
    // consumer first notices it. 400-ms-old packets are already expired.
    write(first);
    std::filesystem::last_write_time(path,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(400));
    GameTelemetryReader oldPacket(path);
    oldPacket.poll(start);
    assert(!oldPacket.current(start));

    write(first);
    std::filesystem::last_write_time(path,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(150));
    GameTelemetryReader slightlyOld(path);
    slightlyOld.poll(start);
    assert(slightlyOld.current(start));
    assert(!slightlyOld.current(start + std::chrono::milliseconds(120)));
}
