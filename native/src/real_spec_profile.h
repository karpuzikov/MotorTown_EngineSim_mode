#pragma once

// Real-spec engine profiles (pipeline/generate_engine_scripts.py): scripts
// marked "// mtes-real-spec-profile: 1", with optional <script>.boost.json.
// Shared by the in-game backend and the offline dynamometer so both drive
// Engine Simulator the same way.

#include "profile_level.h"

#include "engine.h"
#include "intake.h"
#include "piston_engine_simulator.h"
#include "synthesizer.h"
#include "units.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace mtes {

// Tailpipe sound pressure (Pa at 1 m) to PCM: one gain for every engine, so
// loudness differences come from the simulation. Dyno-calibrated 2026-11-03:
// the loudest engines peak just under full scale.
inline constexpr float MotorTownEngineSimRealSpecOutputGain = 100.0f;

inline bool is_real_spec_profile(const std::string& scriptPath) {
    std::ifstream script(scriptPath);
    return script && parse_profile_directive(script, "// mtes-real-spec-profile:", 1).has_value();
}

// Physical exhaust sound at the fixed gain, with Engine Simulator's automatic
// leveler pinned (its min/max gain parameters never reach the filter).
inline void use_real_spec_sound(Simulator* simulator) {
    static_cast<PistonEngineSimulator*>(simulator)->m_physicalExhaustSound = true;
    auto audio = simulator->synthesizer().getAudioParameters();
    audio.volume = MotorTownEngineSimRealSpecOutputGain;
    simulator->synthesizer().setAudioParameters(audio);
    simulator->synthesizer().m_levelingFilter.p_minLevel = 1.0f;
    simulator->synthesizer().m_levelingFilter.p_maxLevel = 1.0f;
}

// Full-load boost: pressure ratio built up between startRpm and fullRpm.
struct FullLoadBoost {
    double pressureRatio = 1.0, startRpm = 0.0, fullRpm = 1.0, chargeTemperatureK = 298.15;
    bool followsThrottle = true; // false: a two-stroke's crankcase or Roots blower always pumps
};

inline double boost_json_number(const std::string& text, const std::string& key) {
    const auto at = text.find("\"" + key + "\"");
    if (at == std::string::npos) throw std::runtime_error("boost file lacks " + key);
    return std::stod(text.substr(text.find(':', at) + 1));
}

// No file: unboosted. A malformed file throws (fail fast).
inline FullLoadBoost read_full_load_boost(const std::filesystem::path& script) {
    auto path = script;
    path.replace_extension(".boost.json");
    FullLoadBoost boost;
    std::ifstream file(path, std::ios::binary);
    if (!file) return boost;
    const std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    boost.pressureRatio = boost_json_number(text, "full_load_pressure_ratio");
    boost.startRpm = boost_json_number(text, "boost_start_rpm");
    boost.fullRpm = boost_json_number(text, "full_boost_rpm");
    boost.chargeTemperatureK = boost_json_number(text, "charge_temperature_k");
    boost.followsThrottle = boost_json_number(text, "follows_throttle") != 0.0;
    return boost;
}

// shortcut: boost follows rpm and throttle at once, no turbo lag or
// wastegate dynamics; upgrade when in-game spool sounds wrong.
inline void apply_boost(Engine* engine, const FullLoadBoost& boost, double rpm, double throttle) {
    const double build = std::clamp(
        (rpm - boost.startRpm) / std::max(1.0, boost.fullRpm - boost.startRpm), 0.0, 1.0)
        * (boost.followsThrottle ? std::clamp(throttle, 0.0, 1.0) : 1.0);
    const double ratio = 1.0 + (boost.pressureRatio - 1.0) * build;
    for (int i = 0; i < engine->getIntakeCount(); ++i) {
        engine->getIntake(i)->setSupplyPressure(units::pressure(ratio, units::atm));
        engine->getIntake(i)->setSupplyTemperature(298.15 + (boost.chargeTemperatureK - 298.15) * build);
    }
}

} // namespace mtes
