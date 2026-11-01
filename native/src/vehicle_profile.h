#pragma once

#include "audio_pipeline.h"

#include <filesystem>
#include <optional>
#include <regex>
#include <string>
#include <unordered_map>
#include <vector>

namespace mtes {

// Profile catalog. First the exact EngineData UObject full name -> script
// (engine_profiles.tsv); then ordered engine-family rules (optional
// engine_families.tsv) matched against the engine asset name, then against
// the stock engine SoundCue the game chose for it, then by the engine's
// maximum RPM. A rule's profile "-" keeps the stock sound (electric motors).
// The audio worker owns reload() and script_for(); no shared mutable access.
class ExactVehicleProfiles final : public VehicleProfileLookup {
public:
    explicit ExactVehicleProfiles(std::filesystem::path modRoot);

    // Reads modRoot/engine_profiles.tsv (EngineData<TAB>relative .mr path)
    // and modRoot/engine_families.tsv (asset|cue<TAB>regex<TAB>.mr or -,
    // or maxrpm<TAB>low-high<TAB>.mr).
    // On malformed, missing or escaping entries, clears every mapping.
    bool reload();
    std::optional<std::string> script_for(const GameTelemetrySample& sample) override;

private:
    enum class Field { Asset, Cue, MaxRpm };
    struct FamilyRule {
        Field field = Field::Asset;
        std::regex pattern;
        double minRpm = 0, maxRpm = 0; // Field::MaxRpm: inclusive range
        std::string script; // empty: keep stock sound
    };
    std::optional<std::string> family_for(const std::string& name, Field field) const;
    std::optional<std::string> rpm_family_for(double maxRpm) const;

    std::filesystem::path m_modRoot;
    std::unordered_map<std::string, std::string> m_profiles;
    std::vector<FamilyRule> m_families;
};

} // namespace mtes
