// Spatial mix, settings and profile directive parsing (no audio device).
#include "mechanical_sound_layer.h"
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

    // A vehicle's exhaust rides along with its engine script.
    {
        const auto plain = parse_engine_sound_spec("C:/mod/assets/es_volvo_d13.mr");
        assert(plain && plain->script == "C:/mod/assets/es_volvo_d13.mr" &&
            plain->exhaustImpulse.empty() && !plain->fullThrottleLoudnessDba);
        const auto truck = parse_engine_sound_spec(
            "C:/mod/assets/es_volvo_d13.mr#exhaust=C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav#loudness=88");
        assert(truck && truck->script == "C:/mod/assets/es_volvo_d13.mr");
        assert(truck->exhaustImpulse == "C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav");
        assert(truck->fullThrottleLoudnessDba && near(*truck->fullThrottleLoudnessDba, 88, 1e-12));
        assert(!parse_engine_sound_spec("a.mr#loudness=88x"));
        assert(!parse_engine_sound_spec("a.mr#loudness=-1"));
    }

    // Real-world loudness: a semi is louder than a hatchback. Engine
    // Simulator's leveled output already drops ~16 dB to idle, so the model
    // adds little there (the Dory idled 37 dB under revving with 25 dB/decade).
    {
        const double semi = engine_loudness_gain_db(88, 1680, 2100, 1.0);
        const double hatchback = engine_loudness_gain_db(74, 5200, 6500, 1.0);
        assert(near(semi - hatchback, 14, 1e-9));
        const double idle = engine_loudness_gain_db(74, 850, 6500, 0.0);
        assert(hatchback - idle > 5 && hatchback - idle < 10);
        assert(near(hatchback - engine_loudness_gain_db(74, 5200, 6500, 0.0), 3, 1e-9));
        assert(engine_loudness_gain_db(130, 9000, 6500, 1.0) == 0.0); // never above full scale
    }

    // A Detroit two-stroke's blower whine follows engine speed (crank order
    // 88); unknown presets do not exist; no RPM, no sound.
    {
        const auto spec = parse_engine_sound_spec("a.mr#exhaust=b.wav#mechanical=detroit_two_stroke#loudness=82");
        assert(spec && spec->mechanicalPreset == "detroit_two_stroke" && spec->exhaustImpulse == "b.wav");
        assert(spec->fullThrottleLoudnessDba && *spec->fullThrottleLoudnessDba == 82);
        assert(!mechanical_sound_preset("unknown"));
        MechanicalSoundLayer layer(*mechanical_sound_preset("detroit_two_stroke"));
        std::vector<std::int16_t> pcm(44100, 0);
        layer.add_to(pcm.data(), pcm.size(), 0.0, 0.002);
        for (auto v : pcm) assert(v == 0);
        layer.add_to(pcm.data(), pcm.size(), 600.0, 0.002); // in game ~0.0004
        const auto bin = [&](double hz) { // Goertzel power
            const double k = 2 * std::cos(2 * 3.14159265358979 * hz / 44100);
            double s1 = 0, s2 = 0;
            for (auto v : pcm) { const double s0 = v + k * s1 - s2; s2 = s1; s1 = s0; }
            return s1 * s1 + s2 * s2 - k * s1 * s2;
        };
        assert(bin(88 * 600 / 60.0) > 10 * bin(88 * 600 / 60.0 + 37)); // whine line 10 dB over the noise
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
