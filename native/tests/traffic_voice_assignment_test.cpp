// Traffic vehicles keep their voice (no recompile); newcomers take freed ones.
#include "traffic_engine_voices.h"

#include <cassert>
#include <chrono>

using mtes::assign_traffic_voices;
using mtes::traffic_vehicle_gone;
using mtes::TrafficAbsenceGrace;

int main() {
    // A, B playing; B left, C arrived: A keeps voice 0, C takes B's voice 1.
    auto assignment = assign_traffic_voices({"A", "B", ""}, {"C", "A"});
    assert(assignment[0] == 1 && assignment[1] == 0);
    // More traffic than voices: the extra vehicle gets none.
    assignment = assign_traffic_voices({"", ""}, {"A", "B", "C"});
    assert(assignment[0] == 0 && assignment[1] == 1 && assignment[2] == -1);
    // A vehicle still listed never loses its voice to a newcomer listed first.
    assignment = assign_traffic_voices({"B", ""}, {"C", "B"});
    assert(assignment[0] == 1 && assignment[1] == 0);
    // A vehicle one Lua list missed (skipped by a scan, half-written or stale
    // file after a slow frame) keeps its voice; only a longer absence ends it.
    const auto listedAt = std::chrono::steady_clock::now();
    assert(!traffic_vehicle_gone(listedAt, listedAt + std::chrono::milliseconds(60)));
    assert(!traffic_vehicle_gone(listedAt, listedAt + TrafficAbsenceGrace));
    assert(traffic_vehicle_gone(listedAt, listedAt + TrafficAbsenceGrace + std::chrono::milliseconds(1)));
    return 0;
}
