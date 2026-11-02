#include "overrun_fuel_cut.h"

#include <cassert>
#include <limits>

using mtes::OverrunFuelCut;

int main() {
    OverrunFuelCut cut;
    const double v8Redline = 5500; // cut-in max(1100, 0.22 * 5500 = 1210) = 1210 rpm

    // Accelerating: always fuelled.
    assert(!cut.update(3000, 1.0, v8Redline));
    // In-game "drill": released throttle while Motor Town still spins 3000 rpm.
    assert(cut.update(3000, 0.0, v8Redline));
    // Coasting down stays cut until close to idle (hysteresis: 0.8 * 1210 = 968).
    assert(cut.update(1500, 0.0, v8Redline));
    assert(cut.update(1000, 0.0, v8Redline));
    assert(!cut.update(950, 0.0, v8Redline)); // idle speed: combustion resumes
    assert(!cut.update(1100, 0.0, v8Redline)); // idle wander does not re-cut
    assert(!cut.update(1200, 0.0, v8Redline));
    // Any throttle while coasting restores fuel immediately.
    assert(cut.update(2500, 0.0, v8Redline));
    assert(!cut.update(2500, 0.1, v8Redline));
    // A light, steady cruise throttle is fuelled.
    assert(!cut.update(2500, 0.03, v8Redline));

    // A truck engine idles low; the 1100-rpm floor keeps idle fuelled.
    OverrunFuelCut truck;
    assert(!truck.update(700, 0.0, 2600));
    assert(truck.update(1800, 0.0, 2600));

    // A motorcycle idles high; its cut-in scales with the redline.
    OverrunFuelCut bike;
    assert(!bike.update(2000, 0.0, 12000)); // 0.22 * 12000 = 2640
    assert(bike.update(5000, 0.0, 12000));

    // A two-stroke's model runs at twice the RPM; the backend passes the
    // real speed and redline. The doubled pair cut its idle (in game the
    // Cheetah idled unfired: a buzz).
    OverrunFuelCut detroit;
    assert(!detroit.update(600, 0.0, 2100));
    assert(detroit.update(1200, 0.0, 4200)); // what the backend used to pass

    // Invalid data never leaves the engine cut.
    assert(!cut.update(std::numeric_limits<double>::quiet_NaN(), 0.0, v8Redline));
    cut.reset();
    assert(!cut.active());
}
