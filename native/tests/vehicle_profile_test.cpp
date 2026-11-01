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

    // Engine-family rules: every Motor Town engine without an exact entry,
    // by its asset name, then by the stock cue the game chose for it.
    std::ofstream(root / "profiles/v6.mr") << "// test engine script\n";
    write(boxer + "\tprofiles/boxer.mr\n");
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "# comment\nasset\telectric\t-\n"
              << "asset\t(^|[^a-z0-9])v6([^0-9]|$)\tprofiles/v6.mr\r\n"
              << "cue\t/v8/\tprofiles/v8.mr\n";
    }
    assert(catalog.reload());
    auto family = *first;
    family.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/V6Sport_DOHC_200HP.V6Sport_DOHC_200HP";
    assert(catalog.script_for(family) &&
        fs::equivalent(*catalog.script_for(family), root / "profiles/v6.mr"));
    assert(fs::equivalent(*catalog.script_for(*first), root / "profiles/boxer.mr")); // exact wins
    family.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/Mystery.Mystery";
    assert(!catalog.script_for(family));
    family.engine_cue = "SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine";
    assert(catalog.script_for(family) &&
        fs::equivalent(*catalog.script_for(family), root / "profiles/v8.mr"));
    family.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/Electric_V8ish.Electric";
    assert(!catalog.script_for(family)); // "-" keeps stock sound, even with a V8 cue
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "asset\t(unclosed\tprofiles/v6.mr\n";
    }
    assert(!catalog.reload() && !catalog.script_for(*first));
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "asset\tv6\t../outside.mr\n";
    }
    assert(!catalog.reload());
    fs::remove(root / "engine_families.tsv");
}
