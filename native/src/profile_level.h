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
// own exhaust impulse response in place of the script's:
//     "<engine.mr>[#distant][#exhaust=<exhaust.wav>]"   (engine_families.tsv has
// the script and exhaust; #distant is added for traffic)
struct EngineSoundSpec {
    std::string script;
    std::string exhaustImpulse; // empty: the script's own impulse responses
    bool distant = false;       // traffic: a shortened exhaust tail, a cheaper voice
};

inline constexpr const char* ExhaustSpecMarker = "#exhaust=";
inline constexpr const char* DistantSpecMarker = "#distant";

inline std::optional<EngineSoundSpec> parse_engine_sound_spec(std::string spec) {
    EngineSoundSpec parsed;
    const auto exhaustAt = spec.find(ExhaustSpecMarker);
    if (exhaustAt != std::string::npos) {
        parsed.exhaustImpulse = spec.substr(
            exhaustAt + std::char_traits<char>::length(ExhaustSpecMarker));
        spec.resize(exhaustAt);
    }
    const std::string distant = DistantSpecMarker;
    if (spec.size() >= distant.size() &&
        spec.compare(spec.size() - distant.size(), distant.size(), distant) == 0) {
        parsed.distant = true;
        spec.resize(spec.size() - distant.size());
    }
    parsed.script = std::move(spec);
    return parsed;
}

// A traffic voice's spec: the same engine and exhaust, cheaper to run.
inline std::string distant_engine_sound_spec(std::string spec) {
    const auto exhaustAt = spec.find(ExhaustSpecMarker);
    spec.insert(exhaustAt == std::string::npos ? spec.size() : exhaustAt, DistantSpecMarker);
    return spec;
}

// Engine Simulator's leveler flattens every engine to one level, idle as loud
// as flat out (measured: within 1 dB), where a real engine spans ~20 dB. The
// synthesizer keeps its timbre; the level follows the game's rpm and pedal,
// relative to flat out at 80% of redline.
inline constexpr double LoudnessDbPerDecadeOfRpm = 15.0;
inline constexpr double LoudnessDbWithClosedThrottle = 6.0;
inline constexpr double LoudnessFloorDb = -40.0;

// Engines differ in size, and the leveler hides that too: a kei truck's 0.66 L
// would play as loud as an industrial 20 L diesel. A real engine's sound power
// follows its power, and power follows displacement: 10 dB per decade, one rule
// for every vehicle, from the displacement of the engine the script describes.
// 0 dB is a 20-litre industrial diesel (anything larger too); a 12.8-litre semi
// engine sits 1.9 dB under it, a 2-litre car 10 dB, and 12 dB is the floor.
inline constexpr double LoudnessReferenceDisplacementLitres = 20.0;
inline constexpr double LoudnessDbPerDecadeOfDisplacement = 10.0;
inline constexpr double LoudnessClassFloorDb = -12.0;

// Unknown displacement (0, NaN): no change.
inline double engine_class_loudness_db(double displacementLitres) {
    if (!std::isfinite(displacementLitres) || !(displacementLitres > 0)) return 0.0;
    return std::clamp(LoudnessDbPerDecadeOfDisplacement *
            std::log10(displacementLitres / LoudnessReferenceDisplacementLitres),
        LoudnessClassFloorDb, 0.0);
}

inline double engine_loudness_gain_db(double rpm, double redlineRpm, double throttle) {
    if (!(rpm > 0) || !(redlineRpm > 0)) return LoudnessFloorDb;
    const double load = std::clamp(std::isfinite(throttle) ? throttle : 0.0, 0.0, 1.0);
    const double gain = LoudnessDbPerDecadeOfRpm * std::log10(rpm / (0.8 * redlineRpm)) +
        LoudnessDbWithClosedThrottle * (load - 1.0);
    return std::clamp(gain, LoudnessFloorDb, 0.0);
}

// Motor Town's rev range often tops out above the real engine's redline (a
// scooter reads 9000, its engine 6500; trucks 2850-3000, engines 2100-2600)
// and Engine Simulator's rev limiter then cuts the ignition. Game and engine
// agree at low rpm (idle); from half the redline up, the rest of the game's
// range is fitted into the engine's, so the game's top rpm is the redline.
// Unknown max rpm, or a game range inside the engine's, changes nothing.
inline double engine_rpm_for_game_rpm(double gameRpm, double gameMaxRpm, double redlineRpm) {
    const double kneeRpm = 0.5 * redlineRpm;
    if (!(redlineRpm > 0) || !(gameMaxRpm > redlineRpm) || !(gameRpm > kneeRpm)) return gameRpm;
    return kneeRpm + (gameRpm - kneeRpm) * (redlineRpm - kneeRpm) / (gameMaxRpm - kneeRpm);
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
