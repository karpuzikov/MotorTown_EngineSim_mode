#pragma once

#include <cmath>
#include <fstream>
#include <optional>
#include <string>

namespace mtes {

// Engine Simulator's synthesizer normalizes every sample peak to ~92% of full
// scale (an automatic gain control with a 23-ms release and up to +5.6 dB of
// boost). In game that made idle and coasting as loud as full throttle, often
// clipped: far louder than Motor Town's own engine sounds. A packaged profile
// states its measured output gain on its first lines instead:
//     // mtes-output-gain: 0.0123
// The synthesizer then scales linearly, limiting only peaks above that target.
inline std::optional<double> parse_profile_directive(std::istream& script,
    const std::string& key, double max) {
    std::string line;
    for (int i = 0; i < 8 && std::getline(script, line); ++i) {
        if (line.rfind(key, 0) != 0) continue;
        try {
            std::size_t used = 0;
            const auto text = line.substr(key.size());
            const double gain = std::stod(text, &used);
            if (text.find_first_not_of(" \t\r", used) != std::string::npos) return std::nullopt;
            if (!std::isfinite(gain) || gain <= 0 || gain > max) return std::nullopt;
            return gain;
        }
        catch (...) { return std::nullopt; }
    }
    return std::nullopt;
}

inline std::optional<double> parse_profile_output_gain(std::istream& script) {
    return parse_profile_directive(script, "// mtes-output-gain:", 100);
}

inline std::optional<double> profile_output_gain(const std::string& path) {
    std::ifstream script(path);
    if (!script) return std::nullopt;
    return parse_profile_output_gain(script);
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
