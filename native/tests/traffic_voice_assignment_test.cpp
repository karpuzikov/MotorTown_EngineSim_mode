// Traffic vehicles keep their voice (no recompile); newcomers take freed ones.
#include "traffic_engine_voices.h"

#include <cassert>

using mtes::assign_traffic_voices;

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
    return 0;
}
