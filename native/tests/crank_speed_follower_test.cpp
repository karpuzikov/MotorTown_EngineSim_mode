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
            const double reached = settledRpm(engine, follower, target, 8.0);
            assert(std::fabs(reached - target) < 0.02 * RedlineRpm);
        }
    }

    // An engine answers the pedal late. The loop must not swing: at steady rpm
    // the crank stays within 3% of redline, and the pedal never slams shut
    // (a pedal shutting twice a second is an audible pulsing).
    for (double authority : {3000.0, 8000.0, 30000.0}) {
        constexpr int DelaySteps = 800; // 80 ms: an engine cycle plus manifold filling
        ToyEngine engine{800.0, authority, 0.2, 400.0};
        CrankSpeedFollower follower;
        double delayedPedal[DelaySteps] = {};
        int slot = 0;
        double lowest = 1e9, highest = 0.0;
        for (double t = 0.0; t < 12.0; t += Step) {
            const double pedal = follower.update(Step, 2500.0, engine.rpm, RedlineRpm);
            engine.step(delayedPedal[slot], Step);
            delayedPedal[slot] = pedal;
            slot = (slot + 1) % DelaySteps;
            if (t > 8.0) { lowest = std::fmin(lowest, engine.rpm); highest = std::fmax(highest, engine.rpm); }
        }
        assert(highest - lowest < 0.03 * RedlineRpm);
    }

    // A rising needle (1500 rpm per second) is followed within 12% of redline: the
    // pedal is worked in proportions of what the engine needs, so it catches up
    // exponentially rather than at once.
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
        assert(worstLag < 0.12 * RedlineRpm);
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
    // is all but closed.
    {
        CrankSpeedFollower follower;
        double pedal = 1.0;
        for (double t = 0.0; t < 1.0; t += Step) pedal = follower.update(Step, 900.0, 1600.0, RedlineRpm);
        assert(pedal < 0.01);
    }

    // Garbage in, closed pedal out.
    CrankSpeedFollower follower;
    assert(follower.update(0.0, 900.0, 900.0, RedlineRpm) == 0.0);
    assert(follower.update(Step, NAN, 900.0, RedlineRpm) == 0.0);
    assert(follower.update(Step, 900.0, 900.0, 0.0) == 0.0);
    return 0;
}
