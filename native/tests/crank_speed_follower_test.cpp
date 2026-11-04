#include "crank_speed_follower.h"

#include <cassert>
#include <cmath>

using mtes::CrankSpeedFollower;

namespace {
// A free-running engine reduced to its crankshaft: the pedal adds speed, friction
// and pumping take it away. rpm per second.
struct ToyEngine {
    double rpm = 0.0;
    double pedalRpmPerSecond;
    double frictionRpmPerSecondPerRpm;
    double constantLossRpmPerSecond;

    void step(double pedal, double seconds) {
        const double change = pedalRpmPerSecond * pedal - constantLossRpmPerSecond -
            frictionRpmPerSecondPerRpm * rpm;
        rpm = std::fmax(0.0, rpm + change * seconds);
    }
};

constexpr double Step = 0.0001; // Engine Simulator steps at 10 kHz and more
constexpr double RedlineRpm = 6000.0;

double settledRpm(ToyEngine &engine, CrankSpeedFollower &follower, double targetRpm, double seconds) {
    for (double t = 0.0; t < seconds; t += Step)
        engine.step(follower.update(Step, targetRpm, engine.rpm, RedlineRpm), Step);
    return engine.rpm;
}
} // namespace

int main() {
    // Engines of very different pedal authority all settle on the target.
    for (double authority : {3000.0, 8000.0, 30000.0}) {
        ToyEngine engine{800.0, authority, 0.2, 400.0};
        CrankSpeedFollower follower;
        for (double target : {900.0, 3500.0, 2000.0, 5200.0}) {
            const double reached = settledRpm(engine, follower, target, 3.0);
            assert(std::fabs(reached - target) < 0.02 * RedlineRpm);
        }
    }

    // A rising needle is caught within a fraction of a second.
    {
        ToyEngine engine{900.0, 8000.0, 0.2, 400.0};
        CrankSpeedFollower follower;
        settledRpm(engine, follower, 900.0, 1.0);
        double worstLag = 0.0;
        for (double t = 0.0; t < 2.0; t += Step) {
            const double target = 900.0 + 1500.0 * t; // 1500 rpm per second
            engine.step(follower.update(Step, target, engine.rpm, RedlineRpm), Step);
            if (t > 0.5) worstLag = std::fmax(worstLag, std::fabs(target - engine.rpm));
        }
        assert(worstLag < 0.05 * RedlineRpm);
    }

    // An unreachable target pins the pedal open without winding up: when the
    // target drops, the pedal lets go promptly.
    {
        ToyEngine engine{900.0, 3000.0, 0.2, 400.0};
        CrankSpeedFollower follower;
        settledRpm(engine, follower, 20000.0, 3.0); // far above anything reachable
        double pedal = 1.0;
        double seconds = 0.0;
        while (pedal > 0.5 && seconds < 1.0) {
            pedal = follower.update(Step, 900.0, engine.rpm, RedlineRpm);
            engine.step(pedal, Step);
            seconds += Step;
        }
        assert(seconds < 0.5);
    }

    // The engine's own idle above the target cannot be pulled down: the pedal
    // is simply closed.
    {
        CrankSpeedFollower follower;
        for (double t = 0.0; t < 1.0; t += Step)
            assert(follower.update(Step, 900.0, 1600.0, RedlineRpm) == 0.0);
    }

    // Garbage in, closed pedal out.
    CrankSpeedFollower follower;
    assert(follower.update(0.0, 900.0, 900.0, RedlineRpm) == 0.0);
    assert(follower.update(Step, NAN, 900.0, RedlineRpm) == 0.0);
    assert(follower.update(Step, 900.0, 900.0, 0.0) == 0.0);
    return 0;
}
