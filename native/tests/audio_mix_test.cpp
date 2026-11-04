// Spatial mix, settings and profile directive parsing (no audio device).
#include "mod_settings.h"
#include "profile_level.h"
#include "spatial_mix.h"

#include <cassert>
#include <cstdio>
#include <cmath>
#include <sstream>

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
        assert(plain && plain->script == "C:/mod/assets/es_volvo_d13.mr" && plain->exhaustImpulse.empty());
        const auto truck = parse_engine_sound_spec(
            "C:/mod/assets/es_volvo_d13.mr#exhaust=C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav");
        assert(truck && truck->script == "C:/mod/assets/es_volvo_d13.mr");
        assert(truck->exhaustImpulse == "C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav");
    }

    // Engine Simulator's leveler makes idle as loud as flat out; the level
    // follows the game's rpm and pedal instead, never above Engine Simulator's.
    {
        assert(near(engine_loudness_gain_db(4400, 5500, 1.0), 0.0, 1e-9));      // flat out at 80% of redline
        assert(engine_loudness_gain_db(5500, 5500, 1.0) == 0.0);                // never above full scale
        const double idle = engine_loudness_gain_db(800, 5500, 0.0);
        assert(idle < -14.0 && idle > -20.0);                                   // ~17 dB under flat out
        assert(near(engine_loudness_gain_db(3000, 5500, 1.0) -
                    engine_loudness_gain_db(3000, 5500, 0.0), 6.0, 1e-9));     // closed throttle is quieter
        assert(engine_loudness_gain_db(2000, 5500, 0.5) < engine_loudness_gain_db(3000, 5500, 0.5));
        assert(engine_loudness_gain_db(0, 5500, 1.0) == LoudnessFloorDb);
        const double cranking = engine_loudness_gain_db(150, 5500, 0.0);
        assert(cranking < -20.0 && cranking > LoudnessFloorDb);                 // cranking is quiet, not silent
        assert(engine_loudness_gain_db(NAN, 5500, 1.0) == LoudnessFloorDb);
    }

    // The game's rev range is fitted into the engine's, so the game's top rpm
    // is the redline and the limiter (redline + 300) is never reached.
    {
        assert(engine_rpm_for_game_rpm(9000, 9000, 6500) == 6500.0);            // scooter at its top
        assert(engine_rpm_for_game_rpm(2900, 2900, 2100) == 2100.0);            // truck at its top
        assert(engine_rpm_for_game_rpm(1000, 9000, 6500) == 1000.0);            // idle untouched
        assert(engine_rpm_for_game_rpm(3250, 9000, 6500) == 3250.0);            // up to half the redline
        double previous = 0;
        for (double rpm = 0; rpm <= 9000; rpm += 250) {                         // monotone, continuous
            const double fitted = engine_rpm_for_game_rpm(rpm, 9000, 6500);
            assert(fitted >= previous && fitted <= rpm);
            previous = fitted;
        }
        assert(engine_rpm_for_game_rpm(5000, 6500, 6500) == 5000.0);            // game range = engine's
        assert(engine_rpm_for_game_rpm(2000, 2850, 3800) == 2000.0);            // game range inside the engine's
        assert(engine_rpm_for_game_rpm(5000, 0, 6500) == 5000.0);               // unknown game max
        assert(engine_rpm_for_game_rpm(5000, 9000, 0) == 5000.0);               // unknown redline
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
