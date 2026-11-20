// The log of what the game reports around an engine start (no audio device).
#include "start_trace.h"

#include <cassert>
#include <cmath>
#include <limits>

using namespace mtes;
using namespace std::chrono_literals;

int main() {
    const auto t0 = StartTrace::Clock::time_point{} + 100s;
    double since = -1.0;

    // Getting into a vehicle opens a window; the first line is at once.
    {
        StartTrace trace;
        assert(trace.update(t0, true, false, 0.0, since) && since == 0.0);
        // Lines follow at the interval, not at every game frame.
        assert(!trace.update(t0 + 16ms, false, false, 0.0, since));
        assert(!trace.update(t0 + 99ms, false, false, 0.0, since));
        assert(trace.update(t0 + 100ms, false, false, 0.0, since) && std::abs(since - 0.1) < 1e-9);
        assert(!trace.update(t0 + 150ms, false, false, 0.0, since));
        assert(trace.update(t0 + 210ms, false, false, 0.0, since));
    }

    // The window closes after six seconds; a steady drive is not logged.
    {
        StartTrace trace;
        assert(trace.update(t0, true, true, 800.0, since));
        bool logged = false;
        for (auto t = 100ms; t <= 6000ms; t += 100ms) logged = trace.update(t0 + t, false, true, 800.0, since);
        assert(logged);                                                   // the last of the window
        assert(!trace.update(t0 + 6101ms, false, true, 800.0, since));
        for (std::chrono::milliseconds t = 7s; t < 600s; t += 100ms) assert(!trace.update(t0 + t, false, true, 2500.0, since));
    }

    // The ignition flag changing, either way, opens a window with a line at once.
    {
        StartTrace trace;
        assert(trace.update(t0, true, false, 0.0, since));
        assert(!trace.update(t0 + 30s, false, false, 0.0, since));
        assert(trace.update(t0 + 30s + 16ms, false, true, 150.0, since) && since == 0.0);
        assert(!trace.update(t0 + 60s, false, true, 800.0, since));
        assert(trace.update(t0 + 60s + 16ms, false, false, 800.0, since) && since == 0.0);
    }

    // The engine leaving rest opens one too (the flag may never change).
    {
        StartTrace trace;
        assert(trace.update(t0, true, true, 0.0, since));
        assert(!trace.update(t0 + 20s, false, true, 10.0, since));
        assert(trace.update(t0 + 20s + 16ms, false, true, 150.0, since) && since == 0.0);
        assert(!trace.update(t0 + 40s, false, true, 700.0, since));        // already turning
        assert(trace.update(t0 + 41s, false, true, 20.0, since) == false); // stopping is not a start
        assert(trace.update(t0 + 42s, false, true, 150.0, since));         // turning again is
    }

    // A window never holds more lines than the limit, and rpm that is not a
    // number is rest.
    {
        StartTrace trace;
        std::size_t lines = 0;
        for (auto t = 0ms; t < 6000ms; t += 1ms) {
            if (trace.update(t0 + t, t == 0ms, true, 800.0, since)) ++lines;
        }
        assert(lines >= 50 && lines <= StartTrace::MaxLinesPerWindow);
        StartTrace nan;
        const double notANumber = std::numeric_limits<double>::quiet_NaN();
        assert(nan.update(t0, true, false, notANumber, since));
        assert(!nan.update(t0 + 20s, false, false, notANumber, since));
    }
}
