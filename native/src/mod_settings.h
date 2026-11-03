#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <istream>
#include <string>

namespace mtes {

// Player-editable settings.ini in the mod folder:
//     volume = 1.0   ; 1 = Motor Town's own engine loudness, 0.5 = half
struct ModSettings {
    double volume = 1.0;
};

inline std::string trim_setting(std::string text) {
    const auto first = text.find_first_not_of(" \t\r");
    if (first == std::string::npos) return {};
    const auto last = text.find_last_not_of(" \t\r");
    return text.substr(first, last - first + 1);
}

inline ModSettings parse_mod_settings(std::istream& input) {
    ModSettings settings;
    std::string line;
    for (int count = 0; count < 200 && std::getline(input, line); ++count) {
        const auto comment = line.find_first_of(";#");
        if (comment != std::string::npos) line.resize(comment);
        const auto equals = line.find('=');
        if (equals == std::string::npos) continue;
        const auto key = trim_setting(line.substr(0, equals));
        const auto value = trim_setting(line.substr(equals + 1));
        if (key != "volume") continue;
        try {
            std::size_t used = 0;
            const double volume = std::stod(value, &used);
            if (used == value.size() && std::isfinite(volume))
                settings.volume = std::clamp(volume, 0.0, 4.0);
        }
        catch (...) { /* keep the default */ }
    }
    return settings;
}

inline ModSettings load_mod_settings(const std::filesystem::path& modRoot) {
    std::ifstream file(modRoot / "settings.ini");
    if (!file) return {};
    return parse_mod_settings(file);
}

} // namespace mtes
