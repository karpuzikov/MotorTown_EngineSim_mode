#pragma once

#include <algorithm>
#include <cmath>

namespace mtes {

// Engine Simulator runs free here, as in its own application: ignition, starter
// and a pedal, with nothing holding the crankshaft. Motor Town's drivetrain is
// not simulated, so this driver's only job is to press the pedal as much as
// needed for the free-running crank to follow the game's rpm, like a driver
// holding a tachometer needle: wide open to catch a rising needle, closed to let
// it fall, and whatever idles it in between.
class CrankSpeedFollower final {
public:
    // Fractions of redline. Tuned on the Engine Simulator demo engines and the
    // generated profiles (see native/tests/crank_speed_follower_test.cpp).
    static constexpr double ProportionalPedalPerRedline = 6.0;
    static constexpr double IntegralPedalPerRedlineSecond = 3.0;
    static constexpr double MeasuredSpeedSmoothingSeconds = 0.04;

    void reset() noexcept {
        m_integralPedal = 0.0;
        m_smoothedRpm = -1.0;
    }

    // The measured speed with the cylinders' pulsing smoothed out; negative
    // before the first update.
    double smoothedRpm() const noexcept { return m_smoothedRpm; }

    // Returns the pedal, 0..1. Call every simulation step.
    double update(double seconds, double targetRpm, double measuredRpm, double redlineRpm) noexcept {
        if (!(seconds > 0.0) || !(redlineRpm > 0.0) || !std::isfinite(targetRpm) ||
            !std::isfinite(measuredRpm)) return 0.0;
        if (m_smoothedRpm < 0.0) m_smoothedRpm = measuredRpm;
        m_smoothedRpm += (measuredRpm - m_smoothedRpm) *
            (1.0 - std::exp(-seconds / MeasuredSpeedSmoothingSeconds));

        const double error = (targetRpm - m_smoothedRpm) / redlineRpm;
        const double unsaturated = ProportionalPedalPerRedline * error + m_integralPedal;
        const double pedal = std::clamp(unsaturated, 0.0, 1.0);
        // Anti-windup: stop integrating while the pedal is pinned and the
        // error would pin it further.
        const bool pinnedFurther = (unsaturated > 1.0 && error > 0.0) ||
            (unsaturated < 0.0 && error < 0.0);
        if (!pinnedFurther) {
            m_integralPedal = std::clamp(
                m_integralPedal + IntegralPedalPerRedlineSecond * error * seconds, 0.0, 1.0);
        }
        return pedal;
    }

private:
    double m_integralPedal = 0.0;
    double m_smoothedRpm = -1.0; // negative until the first measurement
};

} // namespace mtes
