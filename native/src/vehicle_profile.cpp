#include "vehicle_profile.h"

#include <algorithm>
#include <cctype>
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

// Validates a manifest-relative .mr path and resolves it inside root.
std::optional<std::string> packaged_script(const fs::path& root, const std::string& text) {
    const fs::path relative(text);
    if (relative.is_absolute() || relative.has_root_name() ||
        relative.extension() != ".mr") return std::nullopt;
    for (const auto& part : relative) {
        if (part == "..") return std::nullopt;
    }
    std::error_code error;
    const auto script = fs::weakly_canonical(root / relative, error);
    if (error || !contained_in(script, root) ||
        !fs::is_regular_file(script, error) || error) return std::nullopt;
    return script.string();
}

std::vector<std::string> split_tabs(const std::string& line) {
    std::vector<std::string> fields;
    std::size_t start = 0;
    while (true) {
        const auto tab = line.find('\t', start);
        fields.push_back(line.substr(start, tab - start));
        if (tab == std::string::npos) return fields;
        start = tab + 1;
    }
}

} // namespace

std::string vehicle_class_key(const std::string& vehicle) {
    // "Trophy_Taxi_C /Game/Maps/..." -> "trophytaxi"
    std::string name = vehicle.substr(0, vehicle.find(' '));
    if (name.size() > 2 && name.compare(name.size() - 2, 2, "_C") == 0) name.resize(name.size() - 2);
    std::string key;
    for (unsigned char c : name) {
        if (c == '_') continue;
        key.push_back(static_cast<char>(std::tolower(c)));
    }
    return key;
}

ExactVehicleProfiles::ExactVehicleProfiles(fs::path modRoot)
    : m_modRoot(std::move(modRoot)) {}

bool ExactVehicleProfiles::reload() {
    m_profiles.clear(); // Always fail closed, including on partial file reads.
    m_families.clear();

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
        if (key.size() > 512 ||
            std::any_of(key.begin(), key.end(), [](unsigned char c) {
                return c < 0x20 || c == 0x7f;
            })) return false;
        const auto script = packaged_script(root, line.substr(separator + 1));
        if (!script || !entries.emplace(key, *script).second) return false;
    }
    if (file.bad()) return false;

    std::vector<FamilyRule> families;
    const auto familyManifest = root / "engine_families.tsv";
    if (fs::exists(familyManifest, error)) {
        std::ifstream rules(familyManifest, std::ios::binary);
        if (!rules) return false;
        while (std::getline(rules, line)) {
            if (line.size() > 2048) return false;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line.front() == '#') continue;
            const auto fields = split_tabs(line);
            if ((fields.size() != 3 && fields.size() != 4) ||
                (fields.size() == 4 && fields[0] != "vehicle" && fields[0] != "asset") ||
                (fields[0] != "asset" && fields[0] != "cue" && fields[0] != "maxrpm" &&
                 fields[0] != "vehicle") ||
                fields[1].empty() || fields[1].size() > 512 ||
                families.size() >= 1000) return false;
            FamilyRule rule;
            if (fields[0] == "maxrpm") {
                rule.field = Field::MaxRpm;
                const auto dash = fields[1].find('-');
                if (dash == std::string::npos) return false;
                try {
                    std::size_t a = 0, b = 0;
                    const auto low = fields[1].substr(0, dash), high = fields[1].substr(dash + 1);
                    rule.minRpm = std::stod(low, &a);
                    rule.maxRpm = std::stod(high, &b);
                    if (a != low.size() || b != high.size() || !(rule.minRpm >= 0) ||
                        !(rule.maxRpm >= rule.minRpm) || rule.maxRpm > 100000) return false;
                }
                catch (...) { return false; }
            }
            else {
                rule.field = fields[0] == "cue" ? Field::Cue
                    : fields[0] == "vehicle" ? Field::Vehicle : Field::Asset;
                try {
                    rule.pattern = std::regex(fields[1],
                        std::regex::ECMAScript | std::regex::icase | std::regex::optimize);
                }
                catch (const std::regex_error&) { return false; }
            }
            if (fields[2] != "-") {
                const auto script = packaged_script(root, fields[2]);
                if (!script) return false;
                rule.script = *script;
            }
            if (fields.size() == 4) {
                const auto dash = fields[3].find('-');
                try {
                    if (dash == std::string::npos) return false;
                    std::size_t a = 0, b = 0;
                    const auto low = fields[3].substr(0, dash), high = fields[3].substr(dash + 1);
                    rule.minHorsepower = std::stoi(low, &a);
                    rule.maxHorsepower = std::stoi(high, &b);
                    if (a != low.size() || b != high.size() || rule.minHorsepower < 0 ||
                        rule.maxHorsepower < rule.minHorsepower) return false;
                }
                catch (...) { return false; }
            }
            families.push_back(std::move(rule));
        }
        if (rules.bad()) return false;
    }
    m_profiles = std::move(entries);
    m_families = std::move(families);
    return true;
}

std::optional<int> engine_asset_horsepower(const std::string& engineAsset) {
    static const std::regex horsepower(R"((\d{1,5})HP(?![A-Za-z0-9]))", std::regex::icase);
    std::optional<int> found;
    for (std::sregex_iterator it(engineAsset.begin(), engineAsset.end(), horsepower), end;
        it != end; ++it) found = std::stoi((*it)[1].str());
    return found;
}

std::optional<std::string> ExactVehicleProfiles::family_for(
    const std::string& name, Field field, std::optional<int> horsepower) const {
    if (name.empty()) return std::nullopt;
    for (const auto& rule : m_families) {
        if (rule.field != field || !std::regex_search(name, rule.pattern)) continue;
        if (rule.minHorsepower >= 0 && (!horsepower ||
            *horsepower < rule.minHorsepower || *horsepower > rule.maxHorsepower)) continue;
        return rule.script; // empty: keep stock sound
    }
    return std::nullopt;
}

std::optional<std::string> ExactVehicleProfiles::rpm_family_for(double maxRpm) const {
    if (!(maxRpm > 0)) return std::nullopt;
    for (const auto& rule : m_families) {
        if (rule.field == Field::MaxRpm && maxRpm >= rule.minRpm && maxRpm <= rule.maxRpm)
            return rule.script;
    }
    return std::nullopt;
}

std::optional<std::string> ExactVehicleProfiles::script_for(
    const GameTelemetrySample& sample) {
    const auto horsepower = engine_asset_horsepower(sample.engine_asset);
    // An electric motor keeps its stock sound in any vehicle.
    const auto engineFamily = family_for(sample.engine_asset, Field::Asset, horsepower);
    if (engineFamily && engineFamily->empty()) return std::nullopt;
    if (auto car = family_for(vehicle_class_key(sample.vehicle), Field::Vehicle, horsepower)) {
        if (car->empty()) return std::nullopt;
        return car;
    }
    if (sample.engine_asset.empty()) return std::nullopt;
    const auto it = m_profiles.find(sample.engine_asset);
    if (it != m_profiles.end()) return it->second;
    auto family = engineFamily;
    if (!family) family = family_for(sample.engine_cue, Field::Cue);
    if (!family) family = rpm_family_for(sample.max_rpm);
    if (!family || family->empty()) return std::nullopt;
    return family;
}

} // namespace mtes
