#include "lua_mute_lease.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <sstream>
#include <string>
#include <thread>

using namespace mtes;

static std::string read(const std::filesystem::path& path) {
    std::ifstream file(path);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

static void write(const std::filesystem::path& path, const std::string& message) {
    std::ofstream file(path, std::ios::trunc);
    file << message;
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::filesystem::path temp(argv[1]);
    std::filesystem::create_directories(temp);
    auto request = temp / "MotorTownEngineSim_native_mute_request.txt";
    auto ack = temp / "MotorTownEngineSim_native_mute_ack.txt";
    auto diagnostics = temp / "MotorTownEngineSim_mute_diagnostics.txt";
    LuaMuteLeaseLookup lookup(temp);
    GameTelemetrySample sample;
    sample.session = "0123456789ABCDEF";
    sample.sequence = 50;
    sample.vehicle = "MTVehicle DoryWrecker_C_123";
    sample.engine_asset = "MHEngineDataAsset Ford302";
    sample.state = {2400, 0.5, 2, true};

    auto emitter = lookup.stock_for(sample);
    assert(emitter);
    assert(emitter == lookup.stock_for(sample)); // stable identity
    // The strict ACK contract first; the bounded grace is exercised below.
    std::static_pointer_cast<LuaMuteLeaseEmitter>(emitter)->set_transient_grace(
        std::chrono::milliseconds(0));
    assert(!emitter->prepare()); // no mute acknowledgment: don't play
    const auto line = read(request);
    assert(line.find("MTESM1 0123456789ABCDEF 50 ") == 0);
    assert(line.find("4D5456656869636C6520446F7279577265636B65725F435F313233") != std::string::npos);
    std::istringstream parts(line);
    std::string tag, session, seq, token, vehicleHex, assetHex;
    parts >> tag >> session >> seq >> token >> vehicleHex >> assetHex;
    const auto response = [&](const std::string& sessionValue, int sequence,
                               const std::string& tokenValue) {
        return "MTESA1 " + sessionValue + " " + std::to_string(sequence) +
            " " + tokenValue + " " + vehicleHex + " " + assetHex + "\n";
    };
    assert(!emitter->mute());

    // No replay, vehicle confusion or old producer session can start sound.
    write(ack, response("0123456789ABCDE0", 50, token));
    assert(!emitter->prepare());
    write(ack, response(sample.session, 45, token));
    assert(!emitter->prepare());
    write(ack, response(sample.session, 50, token));
    assert(emitter->prepare());
    assert(emitter->mute());

    sample.sequence = 52;
    assert(emitter == lookup.stock_for(sample));
    assert(emitter->prepare()); // short ACK lag is permitted
    sample.sequence = 55;
    assert(emitter == lookup.stock_for(sample));
    assert(!emitter->prepare()); // heartbeat lag is bounded
    assert(read(diagnostics).find("utc_ms=") != std::string::npos);
    assert(read(diagnostics).find("reason=ack_sequence_gap") != std::string::npos);

    write(ack, response(sample.session, 55, token));
    std::filesystem::last_write_time(ack,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(160));
    assert(emitter->prepare()); // a 150-ms game frame must retain the verified lease

    std::filesystem::last_write_time(ack,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(210));
    assert(!emitter->prepare()); // Lua's four 50-ms ticks may already have restored stock
    assert(read(diagnostics).find("reason=ack_age_expired") != std::string::npos);

    write(ack, response(sample.session, 55, token));
    assert(emitter->prepare());
    write(ack, "MTESA0\n");
    assert(!emitter->prepare());
    assert(read(diagnostics).find("reason=ack_revoked") != std::string::npos);

    write(ack, response(sample.session, 55, token));
    assert(emitter->prepare());
    write(ack, "MTESA1 incomplete\n");
    assert(!emitter->prepare());
    assert(read(diagnostics).find("reason=ack_malformed") != std::string::npos);

    write(ack, response(sample.session, 55, token));
    assert(emitter->prepare());
    write(ack, response(sample.session, 55, token + "A"));
    assert(!emitter->prepare());
    assert(read(diagnostics).find("reason=ack_identity_mismatch") != std::string::npos);

    write(ack, response(sample.session, 55, token));
    std::filesystem::last_write_time(ack,
        std::filesystem::file_time_type::clock::now() - std::chrono::seconds(2));
    assert(!emitter->prepare()); // old disk packet never reactivates audio
    assert(emitter->restore());
    assert(read(request).find("MTESM0 0123456789ABCDEF") == 0);

    sample.sequence = 56;
    assert(emitter == lookup.stock_for(sample));
    write(ack, response(sample.session, 56, token));
    assert(!emitter->prepare()); // old ACK cannot reactivate after STOP
    assert(read(request).find(token + "A") != std::string::npos);
    assert(emitter->restore());

    sample.vehicle = "MTVehicle AnotherCar_456";
    assert(lookup.stock_for(sample) != emitter);
    sample.engine_asset.clear();
    assert(!lookup.stock_for(sample));

    // The worker now writes requests concurrently with Lua's game-thread
    // reads. Every observed published file must be a complete command, not
    // the temporary empty/partial result of truncating the active file.
    sample.engine_asset = "MHEngineDataAsset Ford302";
    sample.vehicle = "MTVehicle DoryWrecker_C_123";
    sample.sequence = 70;
    auto concurrent = lookup.stock_for(sample);
    assert(concurrent);
    std::atomic<bool> reading{true};
    std::atomic<bool> incomplete{false};
    std::thread observer([&] {
        while (reading) {
            std::ifstream input(request, std::ios::binary);
            if (!input) continue;
            const std::string content{std::istreambuf_iterator<char>{input},
                std::istreambuf_iterator<char>{}};
            if (content.empty() || content.back() != '\n' ||
                (content.rfind("MTESM1 ", 0) != 0 &&
                 content.rfind("MTESM0 ", 0) != 0)) incomplete = true;
        }
    });
    for (int seq = 70; seq < 570; ++seq) {
        sample.sequence = static_cast<std::uint64_t>(seq);
        assert(lookup.stock_for(sample) == concurrent);
        (void)concurrent->prepare();
    }
    reading = false;
    observer.join();
    assert(!incomplete);
    assert(concurrent->restore());

    // In-game stutter (2026-11-01): each lost ACK stopped the replacement and
    // re-leased the stock cue. A confirmed lease now rides out a torn ACK
    // read, a game hitch and a short sequence lag for a bounded time, while
    // an explicit MTESA0 or a different identity still stops it at once.
    sample.vehicle = "MTVehicle GraceCar_789";
    sample.sequence = 600;
    auto graced = std::static_pointer_cast<LuaMuteLeaseEmitter>(lookup.stock_for(sample));
    assert(graced);
    graced->set_transient_grace(std::chrono::milliseconds(300));
    assert(!graced->prepare()); // publishes the request; nothing confirmed yet
    std::istringstream graceParts(read(request));
    std::string gTag, gSession, gSeq, gToken, gVehicle, gAsset;
    graceParts >> gTag >> gSession >> gSeq >> gToken >> gVehicle >> gAsset;
    const auto graceAck = [&](int sequence) {
        return "MTESA1 " + gSession + " " + std::to_string(sequence) + " " +
            gToken + " " + gVehicle + " " + gAsset + "\n";
    };
    write(ack, "");
    assert(!graced->prepare()); // no confirmed lease: no grace for a torn read
    write(ack, graceAck(600));
    assert(graced->prepare());
    write(ack, "");
    assert(graced->prepare()); // Lua truncated the file and has not written yet
    write(ack, "MTESA1 " + gSession);
    assert(graced->prepare()); // partial line
    write(ack, graceAck(600));
    std::filesystem::last_write_time(ack,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(250));
    assert(graced->prepare()); // game hitch delayed Lua's next ACK
    sample.sequence = 605;
    assert(lookup.stock_for(sample) == graced);
    assert(graced->prepare()); // Lua briefly behind the newest packet
    assert(read(diagnostics).find("grace=1") != std::string::npos);

    write(ack, "MTESA0\n");
    assert(!graced->prepare()); // Lua revoked before restoring stock: stop now

    write(ack, graceAck(605));
    assert(graced->prepare());
    write(ack, "MTESA1 " + gSession + " 605 " + gToken + "B " + gVehicle + " " + gAsset + "\n");
    assert(!graced->prepare()); // a different lease identity is never ridden out

    write(ack, graceAck(605));
    assert(graced->prepare());
    write(ack, "");
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    assert(!graced->prepare()); // grace is bounded
    assert(graced->restore());
}
