#include "lua_mute_lease.h"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <sstream>
#include <string>

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

    write(ack, response(sample.session, 55, token));
    std::filesystem::last_write_time(ack,
        std::filesystem::file_time_type::clock::now() - std::chrono::milliseconds(160));
    assert(!emitter->prepare()); // native rejects ACK before Lua's watchdog

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
}
