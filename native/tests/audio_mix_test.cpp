// Loudness, spatial mix, settings and profile-gain parsing (no audio device).
#include "loudness_leveler.h"
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

// Feed the leveler a "raw" engine at levelDb (calibrated scale) and return
// the output level (dBFS) over the last 100 ms.
double run(LoudnessLeveler& leveler, double levelDb, double seconds) {
    const double amplitude = std::pow(10.0, levelDb / 20.0) * std::sqrt(2.0);
    std::vector<std::int16_t> pcm(static_cast<std::size_t>(seconds * 44100));
    for (std::size_t i = 0; i < pcm.size(); ++i)
        pcm[i] = static_cast<std::int16_t>(std::lround(amplitude * std::sin(i * 0.31) * 32767.0));
    leveler.process(pcm.data(), pcm.size());
    double sum = 0;
    const std::size_t tail = 4410;
    for (std::size_t i = pcm.size() - tail; i < pcm.size(); ++i)
        sum += (pcm[i] / 32768.0) * (pcm[i] / 32768.0);
    return 10 * std::log10(sum / tail);
}
} // namespace

int main() {
    // Profile gain directive: only a well-formed header line counts.
    {
        std::istringstream good("// mtes-output-gain: 0.00211\n// V8\nimport \"engine_sim.mr\"\n");
        const auto gain = parse_profile_output_gain(good);
        assert(gain && near(*gain, 0.00211, 1e-9));
        std::istringstream missing("import \"engine_sim.mr\"\nmain()\n");
        assert(!parse_profile_output_gain(missing));
        std::istringstream junk("// mtes-output-gain: 0.5x\n");
        assert(!parse_profile_output_gain(junk));
        std::istringstream negative("// mtes-output-gain: -1\n");
        assert(!parse_profile_output_gain(negative));
    }

    // Leveler: full throttle stays at the reference; lifting off (raw -20 dB)
    // or idling (-50 dB) is clearly quieter but never silent, and the level
    // settles within ~0.2 s (no slow pumping after a lift-off or a shift).
    {
        LoudnessLeveler leveler;
        leveler.reset();
        const double wot = run(leveler, LoudnessLeveler::ReferenceDbfs, 1.0);
        assert(near(wot, LoudnessLeveler::ReferenceDbfs, 1.0));
        const double lift = run(leveler, LoudnessLeveler::ReferenceDbfs - 20, 0.3);
        assert(lift < wot - 4 && lift > wot - 10);
        const double idle = run(leveler, LoudnessLeveler::ReferenceDbfs - 50, 0.5);
        assert(idle < wot - 10 && idle > wot - 20);
        const double back = run(leveler, LoudnessLeveler::ReferenceDbfs, 0.2);
        assert(near(back, LoudnessLeveler::ReferenceDbfs, 1.5));
        LoudnessLeveler fresh;
        fresh.reset();
        assert(fresh.gain_db() > 20); // a fresh engine is idling, not silent
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
