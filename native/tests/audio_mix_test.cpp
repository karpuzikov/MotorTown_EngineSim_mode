// Spatial mix, settings and profile directive parsing (no audio device).
#include "mod_settings.h"
#include "profile_level.h"
#include "spatial_mix.h"
#include "starter_policy.h"

#include <algorithm>
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
        assert(!plain->distant && !truck->distant);

        // Traffic runs the same engine and exhaust as a cheaper, distant voice.
        const auto distantPlain = distant_engine_sound_spec("C:/mod/assets/es_volvo_d13.mr");
        assert(distantPlain == "C:/mod/assets/es_volvo_d13.mr#distant");
        const auto distantTruck = distant_engine_sound_spec(
            "C:/mod/assets/es_volvo_d13.mr#exhaust=C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav");
        const auto distantPlainSpec = parse_engine_sound_spec(distantPlain);
        const auto distantTruckSpec = parse_engine_sound_spec(distantTruck);
        assert(distantPlainSpec && distantPlainSpec->distant &&
               distantPlainSpec->script == "C:/mod/assets/es_volvo_d13.mr" &&
               distantPlainSpec->exhaustImpulse.empty());
        assert(distantTruckSpec && distantTruckSpec->distant &&
               distantTruckSpec->script == "C:/mod/assets/es_volvo_d13.mr" &&
               distantTruckSpec->exhaustImpulse == "C:/mod/assets/sound-library/mtes-exhaust/truck_stack.wav");
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

    // The level glides to its target: quickly up, so a blip is heard, slowly
    // down, so a lift or a shift fades. An 80 ms glide both ways made every
    // 4-6 dB closed-throttle step a "random volume drop" in game (2026-11-05).
    {
        const double dt = 1.0 / 44100.0;
        const auto settle = [dt](double gain, double target, double seconds) {
            for (int i = 0, n = static_cast<int>(seconds / dt); i < n; ++i)
                gain = glide_loudness_gain(gain, target, dt);
            return gain;
        };
        const auto db = [](double gain) { return 20.0 * std::log10(gain); };
        assert(near(settle(0.0, 1.0, LoudnessRiseSeconds), 1.0 - std::exp(-1.0), 0.01));   // one time constant
        assert(near(settle(1.0, 0.0, LoudnessFallSeconds), std::exp(-1.0), 0.01));
        assert(LoudnessRiseSeconds < LoudnessFallSeconds);
        assert(glide_loudness_gain(0.37, 0.37, dt) == 0.37);                               // at rest at its target
        // Lifting the pedal closes the throttle: 6 dB under. In 50 ms the old
        // glide had fallen 2.3 dB; this one stays within 1 dB, and gets there smoothly.
        assert(db(settle(1.0, 0.5, 0.05)) > -1.0);
        assert(db(settle(1.0, 0.5, 2.0)) < -5.8);
        double gain = 1.0, previous = 1.0, windowStart = 1.0, worstWindowDb = 0.0;
        for (int i = 0; i < 44100; ++i) {
            gain = glide_loudness_gain(gain, 0.5, dt);
            assert(gain <= previous && gain >= 0.5);                                       // monotone, never past the target
            previous = gain;
            if (i % 2205 == 2204) {                                                        // every 50 ms
                worstWindowDb = (std::max)(worstWindowDb, db(windowStart) - db(gain));
                windowStart = gain;
            }
        }
        assert(worstWindowDb < 1.0);                                                       // no step to hear
        // Pressing the pedal swells within a tenth of a second.
        assert(db(settle(0.5, 1.0, 0.1)) > -2.5);
    }

    // The starter cranks until the crank turns at 1.2x its own speed or half
    // the game's rpm, whichever is higher; then the engine runs by itself.
    {
        assert(near(starter_release_rpm(200, 700), 350.0, 1e-9));                  // half of the idle
        assert(near(starter_release_rpm(200, 150), 240.0, 1e-9));                  // 1.2x the starter
        assert(near(starter_release_rpm(-200, 150), 240.0, 1e-9));                 // scripted with a negative speed
        assert(near(starter_release_rpm(200, 0), 240.0, 1e-9));

        // Ignition on: cranks up to the release speed, and again only if the
        // engine falls under 60% of it (a single cylinder swings around one threshold).
        assert(starter_engaged(true, true, false, 100, 700, 350));
        assert(!starter_engaged(true, true, true, 400, 700, 350));
        assert(!starter_engaged(false, true, true, 300, 700, 350));                // released, still above 210
        assert(starter_engaged(false, true, true, 200, 700, 350));                 // stalled: cranks again

        // Ignition flag down: the first key turn is still cranked, fired or
        // not (it was silent, so the start was "binary on/off" in game).
        assert(starter_engaged(false, false, false, 0, 150, 350));
        assert(starter_engaged(true, false, false, 120, 150, 350));
        // An engine that has run and is spinning down is not cranked, nor is
        // one the game already turns faster than the starter could (a reload).
        assert(!starter_engaged(true, false, true, 120, 150, 350));
        assert(!starter_engaged(false, false, false, 0, 800, 350));
        assert(!starter_engaged(false, false, true, 0, 150, 350));
    }

    // The leveler also hides engine size: one global rule, 10 dB per decade of
    // displacement from a 20-litre industrial diesel, floor -12 dB.
    {
        assert(engine_class_loudness_db(20.0) == 0.0);
        assert(engine_class_loudness_db(50.0) == 0.0);                          // never above the reference
        assert(near(engine_class_loudness_db(12.8), -1.94, 0.01));              // semi truck
        assert(near(engine_class_loudness_db(2.0), -10.0, 1e-9));               // car
        assert(engine_class_loudness_db(0.66) == LoudnessClassFloorDb);         // kei truck: the floor
        assert(engine_class_loudness_db(0.1) == LoudnessClassFloorDb);
        assert(engine_class_loudness_db(0.0) == 0.0);                           // unknown: unchanged
        assert(engine_class_loudness_db(NAN) == 0.0);
        assert(engine_class_loudness_db(-3.0) == 0.0);
        double previous = LoudnessClassFloorDb;
        for (double litres = 0.1; litres < 60.0; litres *= 1.1) {               // bigger is never quieter
            const double db = engine_class_loudness_db(litres);
            assert(db >= previous && db <= 0.0);
            previous = db;
        }
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
