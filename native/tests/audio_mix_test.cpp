// Spatial mix, settings and profile directive parsing (no audio device).
#include "mod_settings.h"
#include "profile_level.h"
#include "spatial_mix.h"

#include <cassert>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <sstream>
#include <vector>

using namespace mtes;

namespace {
bool near(double a, double b, double tolerance) { return std::abs(a - b) <= tolerance; }

} // namespace

int main() {
    // Profile header directive: only a well-formed header line counts.
    {
        std::istringstream good("// mtes-rpm-scale: 2\n// V8\nimport \"engine_sim.mr\"\n");
        const auto scale = parse_profile_directive(good, "// mtes-rpm-scale:", 4);
        assert(scale && near(*scale, 2.0, 1e-9));
        std::istringstream missing("// V8\n");
        assert(!parse_profile_directive(missing, "// mtes-rpm-scale:", 4));
        std::istringstream junk("// mtes-rpm-scale: 2x\n");
        assert(!parse_profile_directive(junk, "// mtes-rpm-scale:", 4));
        std::istringstream negative("// mtes-rpm-scale: -1\n");
        assert(!parse_profile_directive(negative, "// mtes-rpm-scale:", 4));
    }

    // Unreal's equal-power pan; gain and settings volume multiply.
    {
        const auto centre = equal_power_gains(SpatialMix{1.0, 0.0, 0}, 1.0);
        assert(near(centre.first, std::sqrt(0.5), 1e-6) && near(centre.second, std::sqrt(0.5), 1e-6));
        const auto right = equal_power_gains(SpatialMix{0.5, 1.0, 0}, 2.0);
        assert(near(right.first, 0.0, 1e-6) && near(right.second, 1.0, 1e-6));
        const auto left = equal_power_gains(SpatialMix{1.0, -1.0, 0}, 1.0);
        assert(near(left.first, 1.0, 1e-6) && near(left.second, 0.0, 1e-6));
        const auto bad = equal_power_gains(SpatialMix{NAN, NAN, 0}, 1.0);
        assert(bad.first == 0 && bad.second == 0);
        assert(xaudio2_lowpass_frequency(0) == 1.0f);
        assert(xaudio2_lowpass_frequency(20000) == 1.0f);
        assert(near(xaudio2_lowpass_frequency(1000), 2 * std::sin(3.14159265 * 1000 / 44100), 1e-5));
    }

    // settings.ini volume.
    {
        std::istringstream file("; comment\nvolume = 0.6 ; quieter\nother = 3\n");
        assert(near(parse_mod_settings(file).volume, 0.6, 1e-9));
        std::istringstream loud("volume=9\n");
        assert(parse_mod_settings(loud).volume == 4.0);
        std::istringstream broken("volume = loud\n");
        assert(parse_mod_settings(broken).volume == 1.0);
        std::istringstream empty("");
        assert(parse_mod_settings(empty).volume == 1.0);
    }
}
