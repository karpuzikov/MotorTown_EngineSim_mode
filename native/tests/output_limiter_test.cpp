#include "output_limiter.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

using namespace mtes;

int main() {
    // A gain at or under the knee leaves the PCM untouched, however loud.
    for (const double gain : {0.0, 0.4068, 0.8, std::numeric_limits<double>::quiet_NaN()}) {
        std::vector<std::int16_t> pcm{-32768, -20000, -1, 0, 1, 20000, 32767};
        const auto before = pcm;
        limit_peaks_for_gain(pcm.data(), pcm.size(), gain);
        assert(pcm == before);
    }

    // A close vehicle: nothing passes full scale after the gain, any input.
    for (const double gain : {0.9, 1.0, 1.79, 4.0}) {
        std::vector<std::int16_t> ramp;
        for (int v = -32768; v <= 32767; v += 37) ramp.push_back(static_cast<std::int16_t>(v));
        ramp.push_back(-32768);
        ramp.push_back(32767);
        auto limited = ramp;
        limit_peaks_for_gain(limited.data(), limited.size(), gain);
        const double knee = 0.8 * 32768.0 / gain;
        double previous = -1e9;
        for (std::size_t i = 0; i < ramp.size(); ++i) {
            assert(std::abs(limited[i] * gain) < 32768.0);          // no hard clip
            assert(std::abs(limited[i]) <= std::abs(ramp[i]));       // only ever reduces
            assert((limited[i] < 0) == (ramp[i] < 0) || limited[i] == 0); // keeps the sign
            if (std::abs(ramp[i]) <= knee) assert(limited[i] == ramp[i]); // below the knee: identical
            if (i + 2 < ramp.size() && i > 0) { // monotonic along the ramp (last two are extremes)
                assert(limited[i] >= previous);
                previous = limited[i];
            }
        }
    }

    // Continuous at the knee: no step where limiting begins.
    {
        const double gain = 1.79;
        const auto knee = static_cast<int>(0.8 * 32768.0 / gain);
        std::vector<std::int16_t> pcm{static_cast<std::int16_t>(knee),
            static_cast<std::int16_t>(knee + 1), static_cast<std::int16_t>(knee + 2)};
        limit_peaks_for_gain(pcm.data(), pcm.size(), gain);
        assert(pcm[1] - pcm[0] <= 1 && pcm[2] - pcm[1] <= 1);
    }
    assert((limit_peaks_for_gain(nullptr, 4, 2.0), true)); // null is ignored
}
