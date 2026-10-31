#include "game_telemetry.h"
#include "vehicle_profile.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;
using namespace mtes;

int main(int argc, char** argv) {
    assert(argc == 2);
    const fs::path root(argv[1]);
    fs::create_directories(root / "profiles");
    std::ofstream(root / "profiles/boxer.mr") << "// test engine script\n";
    std::ofstream(root / "profiles/v8.mr") << "// test engine script\n";
    std::ofstream(root / "profiles/not-script.txt") << "not an engine script\n";

    const std::string boxer = "MT_EngineData /Game/Engines/Boxer.Boxer";
    const std::string v8 = "MT_EngineData /Game/Engines/LSV8.LSV8";
    const auto write = [&root](const std::string& contents) {
        std::ofstream file(root / "engine_profiles.tsv", std::ios::trunc);
        file << contents;
    };
    write("# Exact Motor Town EngineData names, no fuzzy fallback\n" +
        boxer + "\tprofiles/boxer.mr\n" + v8 + "\tprofiles/v8.mr\n");

    ExactVehicleProfiles catalog(root);
    assert(catalog.reload());
    constexpr auto boxerHex = "4D545F456E67696E6544617461202F47616D652F456E67696E65732F426F7865722E426F786572";
    const auto first = parse_game_telemetry(std::string(
        "MTES3 0123456789ABCDEF 1 1700 0.4 1 2 436172415F31 2 6500 ") + boxerHex);
    const auto second = parse_game_telemetry(std::string(
        "MTES3 0123456789ABCDEF 2 2100 0.5 1 3 436172415F32 2 6500 ") + boxerHex);
    assert(first && second && first->vehicle != second->vehicle);
    // Different transient actor IDs of the same engine asset use the same
    // physical engine script, without guessing from RPM or numeric type.
    const auto firstProfile = catalog.script_for(*first);
    const auto secondProfile = catalog.script_for(*second);
    assert(firstProfile && secondProfile);
    assert(fs::equivalent(*firstProfile, root / "profiles/boxer.mr"));
    assert(*firstProfile == *secondProfile);

    const auto unknown = parse_game_telemetry(
        "MTES3 0123456789ABCDEF 3 1700 0.4 1 2 436172415F33 2 6500 -");
    const auto legacy = parse_game_telemetry(
        "MTES2 0123456789ABCDEF 4 1700 0.4 1 2 436172415F34 2 6500");
    assert(unknown && legacy);
    assert(!catalog.script_for(*unknown) && !catalog.script_for(*legacy));
    auto sameEngineTypeDifferentAsset = *first;
    sameEngineTypeDifferentAsset.engine_asset = "UnlistedEngine /Game/Other";
    assert(!catalog.script_for(sameEngineTypeDifferentAsset));

    // A malformed or unsafe manifest must fail as a whole, never retain
    // a partial or stale mapping that could silence the wrong car.
    write(boxer + "\tprofiles/boxer.mr\n" + boxer + "\tprofiles/v8.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    write(boxer + "\t../outside.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    // Canonicalizing away an internal ".." must not silently accept a
    // traversal spelling even when it lands back inside the asset folder.
    write(boxer + "\tprofiles/../profiles/boxer.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    // The telemetry protocol never supplies over-512-byte engine names or
    // control bytes. A malformed key poisons the whole manifest.
    write(boxer + "\tprofiles/boxer.mr\n" +
        std::string(513, 'X') + "\tprofiles/v8.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    write(boxer + "\tprofiles/boxer.mr\n" +
        boxer + std::string(1, '\x01') + "\tprofiles/v8.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    // Windows text-mode streams treat Ctrl-Z (0x1A) as end-of-file. A
    // truncated manifest must never load its valid prefix on Windows.
    write(boxer + "\tprofiles/boxer.mr\n" + std::string(1, '\x1a') +
        "\n" + boxer + "\tprofiles/v8.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    write(boxer + "\tprofiles/not-script.txt\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    write(boxer + "\tprofiles/absent.mr\n");
    assert(!catalog.reload() && !catalog.script_for(*first));
    write("broken row without tab\n");
    assert(!catalog.reload() && !catalog.script_for(*first));

    // CRLF manifests from Windows installers must load without altering keys.
    write(boxer + "\tprofiles/boxer.mr\r\n");
    assert(catalog.reload() && catalog.script_for(*first));

    // A symlinked script that escapes the mod's own asset folder is unsafe.
    const fs::path outside = root.parent_path() / "outside-engine.mr";
    std::ofstream(outside) << "// outside mod root\n";
    std::error_code error;
    fs::create_symlink(outside, root / "profiles/external.mr", error);
    if (!error) {
        write(boxer + "\tprofiles/external.mr\n");
        assert(!catalog.reload() && !catalog.script_for(*first));
    }
    fs::remove(outside, error);
}
