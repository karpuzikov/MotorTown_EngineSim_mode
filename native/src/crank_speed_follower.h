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
    // The pedal an engine needs to hold a speed differs by 10x between engines
    // (a V8 idling and cruising unloaded: 3-9% of the travel; a diesel: over
    // half), and so does how hard the pedal pushes the crank. A fixed gain that
    // suits one swings another between a closed and an open throttle twice a
    // second (at 6 and 3 per redline, a V8 at steady rpm shut the pedal 60% of
    // the time: an audible pulsing). So the loop works in proportions of the
    // pedal the engine needs right now: pedal = needed * exp(P * error), and
    // the needed pedal is integrated in the log domain. Per redline fraction.
    static constexpr double ProportionalPerRedline = 15.0;
    static constexpr double IntegralPerRedlineSecond = 12.0;
    static constexpr double LowestNeededPedal = 0.002;
    static constexpr double InitialNeededPedal = 0.05;
    static constexpr double MeasuredSpeedSmoothingSeconds = 0.04;

    void reset() noexcept {
        m_logNeededPedal = std::log(InitialNeededPedal);
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
        const double unsaturated = std::exp(m_logNeededPedal + ProportionalPerRedline * error);
        const double pedal = std::min(unsaturated, 1.0);
        // Anti-windup: stop integrating while the pedal is pinned open and the
        // error would pin it further, or the need is at its floor.
        const bool pinnedFurther = (unsaturated > 1.0 && error > 0.0) ||
            (m_logNeededPedal <= std::log(LowestNeededPedal) && error < 0.0);
        if (!pinnedFurther) {
            m_logNeededPedal = std::clamp(
                m_logNeededPedal + IntegralPerRedlineSecond * error * seconds,
                std::log(LowestNeededPedal), 0.0);
        }
        return pedal;
    }

private:
    double m_logNeededPedal = std::log(InitialNeededPedal);
    double m_smoothedRpm = -1.0; // negative until the first measurement
};

} // namespace mtes
