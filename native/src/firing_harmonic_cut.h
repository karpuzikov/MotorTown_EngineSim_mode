#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace mtes {

// Cuts an engine's 2nd-4th firing harmonics, tracking RPM. Engine
// Simulator's exhaust pulse is richer in them than a real big diesel: in
// game the Cheetah's 80-250 Hz sat 10-17 dB over a real MC-9 idling (a
// "farting buzz"), and no exhaust, cam or combustion value moved it more
// than ~2 dB. Set per profile: "// mtes-harmonic-cut-db: <dB>" per filter;
// the three overlap, so 14 cuts 120-240 Hz (at 60 Hz firing) by 18-21 dB
// and the thump itself by 1.5 dB.
class FiringHarmonicCut final {
public:
    explicit FiringHarmonicCut(double cutDb, double sampleRate = 44100.0)
        : m_cutDb(cutDb), m_sampleRate(sampleRate) {}

    void process(std::int16_t* pcm, std::size_t frames, double firingHz) {
        if (!(m_cutDb > 0) || !(firingHz > 0)) return;
        for (std::size_t h = 0; h < m_filters.size(); ++h)
            m_filters[h].design((h + 2) * firingHz, -m_cutDb, m_sampleRate);
        for (std::size_t i = 0; i < frames; ++i) {
            double sample = pcm[i];
            for (auto& filter : m_filters) sample = filter.process(sample);
            pcm[i] = static_cast<std::int16_t>(std::clamp(std::lround(sample), -32768L, 32767L));
        }
    }

private:
    struct PeakingFilter { // RBJ peaking EQ, half an octave wide
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        void design(double centreHz, double gainDb, double sampleRate) {
            constexpr double Pi = 3.14159265358979323846;
            const double w = 2 * Pi * std::min(centreHz, 0.45 * sampleRate) / sampleRate;
            const double amplitude = std::pow(10.0, gainDb / 40.0);
            const double alpha = std::sin(w) * std::sinh(std::log(2.0) / 2 * 0.5 * w / std::sin(w));
            const double a0 = 1 + alpha / amplitude;
            b0 = (1 + alpha * amplitude) / a0; b1 = -2 * std::cos(w) / a0; b2 = (1 - alpha * amplitude) / a0;
            a1 = b1; a2 = (1 - alpha / amplitude) / a0;
        }
        double process(double x) {
            const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
    };
    double m_cutDb;
    double m_sampleRate;
    std::array<PeakingFilter, 3> m_filters{};
};

} // namespace mtes
