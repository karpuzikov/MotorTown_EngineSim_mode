#include "vehicle_profile.h"

#include <algorithm>
#include <fstream>
#include <string>
#include <utility>

namespace mtes {
namespace {
namespace fs = std::filesystem;

bool contained_in(const fs::path& file, const fs::path& root) {
    const auto relative = file.lexically_relative(root);
    if (relative.empty() || relative.is_absolute() || relative == fs::path(".")) return false;
    for (const auto& part : relative) {
        if (part == "..") return false;
    }
    return true;
}

} // namespace

ExactVehicleProfiles::ExactVehicleProfiles(fs::path modRoot)
    : m_modRoot(std::move(modRoot)) {}

bool ExactVehicleProfiles::reload() {
    m_profiles.clear(); // Always fail closed, including on partial file reads.

    std::error_code error;
    const auto root = fs::weakly_canonical(m_modRoot, error);
    if (error || !fs::is_directory(root, error) || error) return false;
    const auto manifest = fs::weakly_canonical(root / "engine_profiles.tsv", error);
    if (error || !contained_in(manifest, root) ||
        !fs::is_regular_file(manifest, error) || error) return false;

    // Binary mode avoids Windows CRT Ctrl-Z (0x1A) silently truncating the
    // manifest and making its valid prefix appear to be the complete file.
    std::ifstream file(manifest, std::ios::binary);
    if (!file) return false;
    std::unordered_map<std::string, std::string> entries;
    std::string line;
    while (std::getline(file, line)) {
        if (line.size() > 2048) return false;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line.front() == '#') continue;

        const auto separator = line.find('\t');
        if (separator == std::string::npos || separator == 0 ||
            separator + 1 == line.size() ||
            line.find('\t', separator + 1) != std::string::npos ||
            entries.size() >= 1000) return false;
        const auto key = line.substr(0, separator);
        const auto relativeText = line.substr(separator + 1);
        const fs::path relative(relativeText);
        if (key.size() > 512 ||
            std::any_of(key.begin(), key.end(), [](unsigned char c) {
                return c < 0x20 || c == 0x7f;
            })) return false;
        if (relative.is_absolute() || relative.has_root_name() ||
            relative.extension() != ".mr") return false;
        for (const auto& part : relative) {
            if (part == "..") return false;
        }

        const auto script = fs::weakly_canonical(root / relative, error);
        if (error || !contained_in(script, root) ||
            !fs::is_regular_file(script, error) || error) return false;
        if (!entries.emplace(key, script.string()).second) return false;
    }
    if (file.bad()) return false;
    m_profiles = std::move(entries);
    return true;
}

std::optional<std::string> ExactVehicleProfiles::script_for(
    const GameTelemetrySample& sample) {
    if (sample.engine_asset.empty()) return std::nullopt;
    const auto it = m_profiles.find(sample.engine_asset);
    if (it == m_profiles.end()) return std::nullopt;
    return it->second;
}

} // namespace mtes
