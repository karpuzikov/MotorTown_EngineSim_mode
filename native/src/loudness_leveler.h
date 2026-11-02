#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace mtes {

// Engine Simulator's raw output spans ~50 dB between a closed-throttle idle
// and full throttle near redline (fuel cut-off on overrun is ~35 dB below
// full throttle); real cars and Motor Town differ by roughly 10-15 dB.
//
// Feed-forward 3:1 compressor on the PCM as it is read: no feedback delay.
// (The previous slow feedback leveler pumped audibly in game: lifting off or
// shifting dropped the loudness, which then crept back over ~0.5 s.)
// Input must come from a calibrated profile whose full-throttle RMS sits at
// ReferenceDbfs.
class LoudnessLeveler {
public:
    static constexpr double ReferenceDbfs = -14.0;
    static constexpr double Ratio = 3.0;
    static constexpr double MaxBoostDb = 36.0;
    static constexpr double MaxCutDb = 9.0;
    // Symmetric mean-square window: a peak-biased detector would cut
    // full throttle below the calibrated reference.
    static constexpr double WindowSeconds = 0.04;
    static constexpr double SampleRate = 44100.0;
    static constexpr double LimitKnee = 0.85;
    static constexpr double StartLevelDb = ReferenceDbfs - 40.0; // fresh engine idles

    void reset() noexcept { m_power = power(StartLevelDb); }

    void process(std::int16_t* pcm, std::size_t frames) noexcept {
        if (!pcm) return;
        static const double smoothing = 1.0 - std::exp(-1.0 / (WindowSeconds * SampleRate));
        for (std::size_t i = 0; i < frames; ++i) {
            const double x = pcm[i] / 32768.0;
            const double p = x * x;
            m_power += smoothing * (p - m_power);
            pcm[i] = to_pcm(soft_limit(x * std::pow(10.0, gain_db() / 20.0)));
        }
    }

    double gain_db() const noexcept {
        const double level = 10.0 * std::log10(std::max(m_power, 1e-12));
        return std::clamp((ReferenceDbfs - level) * (1.0 - 1.0 / Ratio), -MaxCutDb, MaxBoostDb);
    }

private:
    static double power(double db) noexcept { return std::pow(10.0, db / 10.0); }
    static double soft_limit(double y) noexcept {
        const double magnitude = std::abs(y);
        if (magnitude <= LimitKnee) return y;
        const double room = 1.0 - LimitKnee;
        const double limited = LimitKnee + room * std::tanh((magnitude - LimitKnee) / room);
        return y < 0 ? -limited : limited;
    }
    static std::int16_t to_pcm(double y) noexcept {
        return static_cast<std::int16_t>(std::lround(std::clamp(y, -1.0, 32767.0 / 32768.0) * 32768.0));
    }

    double m_power = power(StartLevelDb); // mean square, full scale = 1
};

} // namespace mtes
