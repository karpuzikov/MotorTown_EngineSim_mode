#pragma once

#include <chrono>
#include <cstddef>

namespace mtes {

// What the game itself reports around an engine start, for UE4SS.log: the first
// seconds after the player gets into a vehicle, after the ignition flag changes
// and after the engine leaves rest. The key turn was "binary on/off" in game and
// the recordings cannot say what Motor Town reports while it is cranking (its
// rpm, and whether the ignition flag is up yet), which decides how the start is
// played. Outside those windows nothing is logged.
class StartTrace {
public:
    using Clock = std::chrono::steady_clock;

    static constexpr std::chrono::milliseconds Window{6000};
    static constexpr std::chrono::milliseconds Interval{100};
    static constexpr std::size_t MaxLinesPerWindow = 80;
    static constexpr double RestRpm = 50.0; // under this the engine is not turning

    // Call with each update's telemetry. True when to log a line now, with the
    // seconds since the window opened.
    bool update(Clock::time_point now, bool newVehicle, bool ignition, double rpm,
                double &secondsSinceOpened) {
        const bool atRest = !(rpm >= RestRpm); // also true for NaN
        const bool opens = newVehicle || !m_known || ignition != m_ignition ||
            (m_atRest && !atRest);
        m_known = true;
        m_ignition = ignition;
        m_atRest = atRest;
        if (opens) {
            m_opened = now;
            m_open = true;
            m_lines = 0;
            m_nextLine = now;
        }
        if (!m_open) return false;
        if (now - m_opened > Window || m_lines >= MaxLinesPerWindow) {
            m_open = false;
            return false;
        }
        if (now < m_nextLine) return false;
        m_nextLine = now + Interval;
        ++m_lines;
        secondsSinceOpened = std::chrono::duration<double>(now - m_opened).count();
        return true;
    }

private:
    bool m_known = false;
    bool m_ignition = false;
    bool m_atRest = true;
    bool m_open = false;
    Clock::time_point m_opened{};
    Clock::time_point m_nextLine{};
    std::size_t m_lines = 0;
};

} // namespace mtes
