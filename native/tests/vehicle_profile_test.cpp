#include "game_telemetry.h"
#include "vehicle_profile.h"
#include "profile_level.h"

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
    // The game's default V8 cue says nothing: the engine's MaxRPM decides.
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "asset\telectric\t-\nmaxrpm\t0-3300\tprofiles/boxer.mr\n"
              << "maxrpm\t3301-30000\tprofiles/v6.mr\n";
    }
    assert(catalog.reload());
    family.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/Mystery.Mystery";
    family.max_rpm = 2500;
    assert(fs::equivalent(*catalog.script_for(family), root / "profiles/boxer.mr"));
    family.max_rpm = 6000;
    assert(fs::equivalent(*catalog.script_for(family), root / "profiles/v6.mr"));
    family.max_rpm = 0;
    assert(!catalog.script_for(family));
    family.max_rpm = 6000;
    family.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/Electric.Electric";
    assert(!catalog.script_for(family));
    for (const char* bad : {"maxrpm\t5000\tprofiles/v6.mr\n", "maxrpm\t9-1\tprofiles/v6.mr\n",
                            "maxrpm\tx-9\tprofiles/v6.mr\n"}) {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << bad;
        rules.close();
        assert(!catalog.reload());
    }
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

    // Per-vehicle rules: the real car's engine wins over the engine asset.
    assert(vehicle_class_key("Trophy_Taxi_C /Game/Maps/Jeju/Jeju_World.Jeju_World:PersistentLevel.Trophy_Taxi_C_1") == "trophytaxi");
    assert(vehicle_class_key("DoryWrecker_C /Game/x") == "dorywrecker");
    assert(vehicle_class_key("") .empty());
    write(boxer + "\tprofiles/boxer.mr\n");
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "vehicle\t^trophy\tprofiles/v6.mr\nvehicle\t^pulse\t-\n";
    }
    assert(catalog.reload());
    auto car = *first;
    car.vehicle = "Trophy_Taxi_C /Game/Maps/Jeju/Jeju_World.Jeju_World:PersistentLevel.Trophy_Taxi_C_7";
    assert(fs::equivalent(*catalog.script_for(car), root / "profiles/v6.mr")); // beats exact boxer
    car.vehicle = "Pulse_C /Game/x";
    assert(!catalog.script_for(car)); // electric car keeps stock sound
    car.vehicle = "Other_C /Game/x";
    assert(fs::equivalent(*catalog.script_for(car), root / "profiles/boxer.mr"));

    // The installed engine's horsepower picks the real engine of that power;
    // an electric motor keeps the stock sound even in a combustion car.
    assert(engine_asset_horsepower("MHEngineDataAsset /Game/Cars/Parts/Engine/MediumDuty_330HP.MediumDuty_330HP") == 330);
    assert(engine_asset_horsepower("FordSmalBlock302_V8_5L_140HP") == 140);
    assert(!engine_asset_horsepower("Mystery.Mystery"));
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "asset\telectric\t-\n"
                 "vehicle\t^kira\tprofiles/boxer.mr\t0-217\n"
                 "vehicle\t^kira\tprofiles/v6.mr\t218-100000\n";
    }
    assert(catalog.reload());
    car.vehicle = "Kira_Van_C /Game/x";
    car.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/MediumDuty_190HP.MediumDuty_190HP";
    assert(fs::equivalent(*catalog.script_for(car), root / "profiles/boxer.mr"));
    car.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/MediumDuty_330HP.MediumDuty_330HP";
    assert(fs::equivalent(*catalog.script_for(car), root / "profiles/v6.mr"));
    car.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/Electric_300HP.Electric_300HP";
    assert(!catalog.script_for(car));
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "cue\tv6\tprofiles/v6.mr\t0-10\n"; // horsepower only on vehicle/asset
    }
    assert(!catalog.reload());

    // A vehicle's own exhaust must be a packaged impulse response.
    fs::create_directories(root / "assets/sound-library/mtes-exhaust");
    { std::ofstream wav(root / "assets/sound-library/mtes-exhaust/truck_stack.wav"); wav << "RIFF"; }
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "vehicle\t^kira\tprofiles/v6.mr#exhaust=mtes-exhaust/truck_stack.wav\n";
    }
    assert(catalog.reload());
    car.engine_asset = "MHEngineDataAsset /Game/Cars/Parts/Engine/MediumDuty_190HP.MediumDuty_190HP";
    const auto spec = parse_engine_sound_spec(*catalog.script_for(car));
    assert(spec && fs::equivalent(spec->script, root / "profiles/v6.mr"));
    assert(fs::equivalent(spec->exhaustImpulse, root / "assets/sound-library/mtes-exhaust/truck_stack.wav"));
    {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "vehicle\t^kira\tprofiles/v6.mr#exhaust=mtes-exhaust/truck_stack.wav#loudness=84\n";
    }
    assert(catalog.reload());
    const auto calibrated = parse_engine_sound_spec(*catalog.script_for(car));
    assert(calibrated && calibrated->fullThrottleLoudnessDba && *calibrated->fullThrottleLoudnessDba == 84);
    for (const char* bad : {"profiles/v6.mr#exhaust=mtes-exhaust/missing.wav",
                            "profiles/v6.mr#exhaust=../../outside.wav",
                            "profiles/v6.mr#exhaust=mtes-exhaust/truck_stack.mr",
                            "profiles/v6.mr#exhaust=mtes-exhaust/truck_stack.wav#loudness=0"}) {
        std::ofstream rules(root / "engine_families.tsv", std::ios::trunc);
        rules << "vehicle\t^kira\t" << bad << "\n";
        rules.close();
        assert(!catalog.reload());
    }
    fs::remove(root / "engine_families.tsv");
}
