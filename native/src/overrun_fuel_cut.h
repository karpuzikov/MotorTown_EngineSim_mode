#pragma once

#include <algorithm>
#include <cmath>

namespace mtes {

// Deceleration fuel cut-off, as every modern engine ECU does it: coasting
// off-throttle above idle injects no fuel, so no cylinder fires. Without it
// the synthesizer kept firing at closed throttle while Motor Town's RPM
// dragged the crankshaft (in game: coasting sounded like a wall drill).
// Fuel returns when the driver touches the throttle or RPM nears idle.
class OverrunFuelCut {
public:
    // redlineRpm: the loaded engine model's redline, used to scale the cut-in
    // speed from motorcycles (high idle) to trucks (low idle).
    bool update(double rpm, double throttle, double redlineRpm) noexcept {
        if (!std::isfinite(rpm) || !std::isfinite(throttle) || !std::isfinite(redlineRpm)) {
            m_cut = false;
            return m_cut;
        }
        const double cutAbove = std::max(MinCutRpm, CutFractionOfRedline * redlineRpm);
        if (throttle > ResumeThrottle || rpm < ResumeFraction * cutAbove) m_cut = false;
        else if (throttle < CutThrottle && rpm > cutAbove) m_cut = true;
        return m_cut;
    }
    void reset() noexcept { m_cut = false; }
    bool active() const noexcept { return m_cut; }

    static constexpr double MinCutRpm = 1100.0;
    static constexpr double CutFractionOfRedline = 0.22;
    static constexpr double ResumeFraction = 0.8;
    static constexpr double CutThrottle = 0.02;
    static constexpr double ResumeThrottle = 0.05;

private:
    bool m_cut = false;
};

} // namespace mtes
