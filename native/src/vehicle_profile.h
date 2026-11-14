#pragma once

#include "audio_pipeline.h"

#include <filesystem>
#include <optional>
#include <regex>
#include <string>
#include <unordered_map>
#include <vector>

namespace mtes {

// Motor Town vehicle blueprint class as a match key: "Trophy_Taxi_C ..." ->
// "trophytaxi".
std::string vehicle_class_key(const std::string& vehicle);

// Horsepower in a Motor Town engine asset name ("MediumDuty_330HP" -> 330).
std::optional<int> engine_asset_horsepower(const std::string& engineAsset);

// Profile catalog. Electric engine assets keep their stock sound first. Then
// the car itself: the real engine of the real car the Motor Town vehicle is
// based on, for the installed engine's horsepower (engine_families.tsv
// "vehicle" rules on the blueprint class, lower case without underscores,
// e.g. "trophytaxi", with an optional 4th column "low-high" horsepower).
// Then the exact EngineData UObject full name -> script
// (engine_profiles.tsv); then ordered engine-family rules (optional
// engine_families.tsv) matched against the engine asset name, then against
// the stock engine SoundCue the game chose for it, then by the engine's
// maximum RPM. A rule's profile "-" keeps the stock sound (electric motors).
// The audio worker owns reload() and script_for(); no shared mutable access.
class ExactVehicleProfiles final : public VehicleProfileLookup {
public:
    explicit ExactVehicleProfiles(std::filesystem::path modRoot);

    // Reads modRoot/engine_profiles.tsv (EngineData<TAB>relative .mr path)
    // and modRoot/engine_families.tsv (vehicle|asset|cue<TAB>regex<TAB>.mr or -
    // [<TAB>low-high horsepower], or maxrpm<TAB>low-high<TAB>.mr).
    // On malformed, missing or escaping entries, clears every mapping.
    bool reload();
    std::optional<std::string> script_for(const GameTelemetrySample& sample) override;

private:
    enum class Field { Vehicle, Asset, Cue, MaxRpm };
    struct FamilyRule {
        Field field = Field::Asset;
        std::regex pattern;
        double minRpm = 0, maxRpm = 0; // Field::MaxRpm: inclusive range
        int minHorsepower = -1, maxHorsepower = -1; // -1: any engine
        std::string script; // empty: keep stock sound
    };
    std::optional<std::string> family_for(const std::string& name, Field field,
        std::optional<int> horsepower = std::nullopt) const;
    std::optional<std::string> rpm_family_for(double maxRpm) const;

    std::filesystem::path m_modRoot;
    std::unordered_map<std::string, std::string> m_profiles;
    std::vector<FamilyRule> m_families;
};

} // namespace mtes
