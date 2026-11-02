#pragma once

#include <cmath>
#include <fstream>
#include <optional>
#include <string>

namespace mtes {

// A profile header directive on its first lines, e.g. "// mtes-rpm-scale: 2".
inline std::optional<double> parse_profile_directive(std::istream& script,
    const std::string& key, double max) {
    std::string line;
    for (int i = 0; i < 8 && std::getline(script, line); ++i) {
        if (line.rfind(key, 0) != 0) continue;
        try {
            std::size_t used = 0;
            const auto text = line.substr(key.size());
            const double value = std::stod(text, &used);
            if (text.find_first_not_of(" \t\r", used) != std::string::npos) return std::nullopt;
            if (!std::isfinite(value) || value <= 0 || value > max) return std::nullopt;
            return value;
        }
        catch (...) { return std::nullopt; }
    }
    return std::nullopt;
}

// A vehicle's engine sound: an engine script, optionally with the vehicle's
// own exhaust impulse response in place of the script's:
//     "<engine.mr>#exhaust=<exhaust.wav>"   (engine_families.tsv, profiles/exhaust)
struct EngineSoundSpec {
    std::string script;
    std::string exhaustImpulse; // empty: the script's own impulse responses
};

inline constexpr const char* ExhaustSpecMarker = "#exhaust=";

inline EngineSoundSpec parse_engine_sound_spec(const std::string& spec) {
    const auto marker = spec.find(ExhaustSpecMarker);
    if (marker == std::string::npos) return {spec, {}};
    return {spec.substr(0, marker),
        spec.substr(marker + std::char_traits<char>::length(ExhaustSpecMarker))};
}

// Two-stroke engines fire every revolution. Engine Simulator only models
// four-strokes, so such a profile runs at this multiple of the game RPM:
//     // mtes-rpm-scale: 2
inline double profile_rpm_scale(const std::string& path) {
    std::ifstream script(path);
    if (!script) return 1.0;
    return parse_profile_directive(script, "// mtes-rpm-scale:", 4).value_or(1.0);
}

} // namespace mtes
