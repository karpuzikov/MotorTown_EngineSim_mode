#pragma once

#include <algorithm>
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
// own exhaust impulse response in place of the script's, and the vehicle's
// real-world loudness (full-throttle pass-by dB(A) at 7.5 m):
//     "<engine.mr>[#exhaust=<exhaust.wav>][#mechanical=<preset>][#loudness=<dBA>]"
// (engine_families.tsv; presets: mechanical_sound_layer.h)
struct EngineSoundSpec {
    std::string script;
    std::string exhaustImpulse;               // empty: the script's own impulse responses
    std::optional<double> fullThrottleLoudnessDba; // none: Engine Simulator's level as is
    std::string mechanicalPreset;             // empty: exhaust sound only
};

inline constexpr const char* ExhaustSpecMarker = "#exhaust=";
inline constexpr const char* LoudnessSpecMarker = "#loudness=";
inline constexpr const char* MechanicalSpecMarker = "#mechanical=";

// Fails (nullopt) on a malformed gain: a wrong level must not play.
inline std::optional<EngineSoundSpec> parse_engine_sound_spec(std::string spec) {
    EngineSoundSpec parsed;
    const auto loudnessAt = spec.find(LoudnessSpecMarker);
    if (loudnessAt != std::string::npos) {
        const auto text = spec.substr(loudnessAt + std::char_traits<char>::length(LoudnessSpecMarker));
        try {
            std::size_t used = 0;
            const double loudness = std::stod(text, &used);
            if (used != text.size() || !std::isfinite(loudness) || loudness < 40 || loudness > 130)
                return std::nullopt;
            parsed.fullThrottleLoudnessDba = loudness;
        }
        catch (...) { return std::nullopt; }
        spec.resize(loudnessAt);
    }
    const auto mechanicalAt = spec.find(MechanicalSpecMarker);
    if (mechanicalAt != std::string::npos) {
        parsed.mechanicalPreset = spec.substr(
            mechanicalAt + std::char_traits<char>::length(MechanicalSpecMarker));
        spec.resize(mechanicalAt);
    }
    const auto exhaustAt = spec.find(ExhaustSpecMarker);
    if (exhaustAt != std::string::npos) {
        parsed.exhaustImpulse = spec.substr(
            exhaustAt + std::char_traits<char>::length(ExhaustSpecMarker));
        spec.resize(exhaustAt);
    }
    parsed.script = std::move(spec);
    return parsed;
}

// Real-world engine loudness. Engine Simulator's raw output puts idle ~56 dB
// under full throttle (measured, all profiles; real engines ~20 dB) and its
// leveler flattens every engine to one peak level (in game: a hatchback as
// loud as a semi). So its leveler keeps the timbre and this sets the level,
// in dB of output gain for a vehicle that makes fullThrottleLoudnessDba at
// 7.5 m flat out at 80% of redline:
//   - leveled output already falls ~16 dB from revving to idle (sparse
//     pulses at low RPM; in-game recording 2026-11-02), so RPM and load
//     add only 4 dB per decade and 3 dB for a closed throttle (the leveler
//     would otherwise make coasting as loud as flat out). (25 dB/decade + 6 dB put the
//     Dory's idle 37 dB under revving: "almost non-existent".)
//   - 98 dB(A) plays at full scale; 7.5 m distance is in the 3D mix.
inline double engine_loudness_gain_db(double fullThrottleLoudnessDba, double rpm,
    double redlineRpm, double throttle) {
    if (!(rpm > 0) || !(redlineRpm > 0)) return -90.0;
    const double load = std::clamp(std::isfinite(throttle) ? throttle : 0.0, 0.0, 1.0);
    const double gain = fullThrottleLoudnessDba - 98.0 +
        4.0 * std::log10(rpm / (0.8 * redlineRpm)) + 3.0 * (load - 1.0);
    return std::clamp(gain, -90.0, 0.0);
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
