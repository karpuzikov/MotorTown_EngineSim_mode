#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace mtes {

// Engine Simulator's raw output spans ~50 dB between a closed-throttle idle
// and full throttle near redline. Its own leveler flattens all of it to full
// scale within ~23 ms (the in-game "always flat out" loudness); a fixed gain
// instead leaves idle inaudible. Motor Town's engine sounds sit in between.
//
// This is a slow 4:1 compressor around the profile's calibrated full-throttle
// level. It only computes a gain: the backend applies it as the synthesizer's
// leveler gain cap, i.e. before 16-bit quantization, where the synthesizer's
// instant peak limiter still catches a sudden throttle stab.
class LoudnessLeveler {
public:
    static constexpr double ReferenceDbfs = -14.0; // calibrated full-throttle RMS
    static constexpr double Ratio = 4.0;
    static constexpr double MaxBoostDb = 42.0;
    static constexpr double MaxCutDb = 12.0;
    static constexpr double AttackSeconds = 0.05;
    static constexpr double ReleaseSeconds = 0.25;
    static constexpr double RiseDbPerSecond = 90.0;   // e.g. lift-off to idle
    static constexpr double FallDbPerSecond = 150.0;  // e.g. idle to full throttle

    // A freshly loaded engine is idling: start at an idle-level gain.
    static constexpr double StartLevelDb = ReferenceDbfs - 40.0;

    void reset() noexcept {
        m_level = power(StartLevelDb);
        m_gainDb = start_gain_db();
        m_sum = 0.0;
        m_count = 0;
    }

    // PCM produced at the gain returned by the previous update().
    void observe(const std::int16_t* pcm, std::size_t frames) noexcept {
        if (!pcm) return;
        for (std::size_t i = 0; i < frames; ++i) {
            const double x = pcm[i] / 32768.0;
            m_sum += x * x;
        }
        m_count += frames;
    }

    // Returns the linear gain for the next interval of `seconds`.
    double update(double seconds) noexcept {
        if (!std::isfinite(seconds) || seconds <= 0) return gain();
        if (m_count > 0) {
            // Level the engine makes at the calibrated scale, without our gain.
            const double raw = (m_sum / m_count) / power(m_gainDb);
            const double tau = raw > m_level ? AttackSeconds : ReleaseSeconds;
            m_level += (1.0 - std::exp(-seconds / tau)) * (raw - m_level);
            m_sum = 0.0;
            m_count = 0;
        }
        const double levelDb = 10.0 * std::log10(std::max(m_level, 1e-12));
        const double target = std::clamp(
            (ReferenceDbfs - levelDb) * (1.0 - 1.0 / Ratio), -MaxCutDb, MaxBoostDb);
        m_gainDb += std::clamp(target - m_gainDb,
            -FallDbPerSecond * seconds, RiseDbPerSecond * seconds);
        return gain();
    }

    double gain() const noexcept { return std::pow(10.0, m_gainDb / 20.0); }
    double gain_db() const noexcept { return m_gainDb; }

private:
    static double power(double db) noexcept { return std::pow(10.0, db / 10.0); }
    static double start_gain_db() noexcept {
        return std::min(MaxBoostDb, (ReferenceDbfs - StartLevelDb) * (1.0 - 1.0 / Ratio));
    }

    double m_level = power(StartLevelDb); // mean square, full scale = 1
    double m_gainDb = start_gain_db();
    double m_sum = 0.0;
    std::size_t m_count = 0;
};

} // namespace mtes
