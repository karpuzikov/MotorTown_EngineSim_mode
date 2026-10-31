#pragma once

#include "audio_pipeline.h"

#include <filesystem>
#include <optional>
#include <string>
#include <unordered_map>

namespace mtes {

// Development profile catalog: exact EngineData UObject full name -> script.
// A future installer must bundle curated mappings and Engine Simulator assets.
// The game thread owns reload() and script_for(); no shared mutable access.
class ExactVehicleProfiles final : public VehicleProfileLookup {
public:
    explicit ExactVehicleProfiles(std::filesystem::path modRoot);

    // Reads modRoot/engine_profiles.tsv (EngineData<TAB>relative .mr path).
    // On malformed, missing or escaping entries, clears every mapping.
    bool reload();
    std::optional<std::string> script_for(const GameTelemetrySample& sample) override;

private:
    std::filesystem::path m_modRoot;
    std::unordered_map<std::string, std::string> m_profiles;
};

} // namespace mtes
