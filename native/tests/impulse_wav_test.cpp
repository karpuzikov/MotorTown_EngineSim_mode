#include "impulse_wav.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

using namespace mtes;

int main(int argc, char **argv) {
    // Hand-authored RIFF mono PCM16, 44100 Hz: -32768, 0, +32767.
    const std::vector<std::uint8_t> pcm16 = {
        'R','I','F','F', 42,0,0,0, 'W','A','V','E',
        'f','m','t',' ',16,0,0,0, 1,0, 1,0,
        0x44,0xAC,0,0, 0x88,0x58,1,0, 2,0, 16,0,
        'd','a','t','a',6,0,0,0, 0,0x80, 0,0, 0xFF,0x7F
    };
    const auto decoded = parse_impulse_wav(pcm16);
    assert(decoded.size() == 3);
    assert(decoded[0] == -32768 && decoded[1] == 0 && decoded[2] == 32767);
    // Upstream convolution treats amplitudes <=100 as a zero-length impulse,
    // which its DSP must never attempt to process.
    assert(!usable_impulse_for_engine_sim({0, 0, 0}));
    assert(!usable_impulse_for_engine_sim({-100, 0, 100}));
    assert(usable_impulse_for_engine_sim({101}));
    assert(usable_impulse_for_engine_sim({-32768}));

    // settings.ini "muffler" swaps only Engine Simulator's road muffler for its brightened copies.
    const std::filesystem::path muffler = "C:/mod/assets/sound-library/smooth/smooth_39.wav";
    assert(muffler_variant_path(muffler, MufflerTreble::Standard) == muffler);
    assert(muffler_variant_path(muffler, MufflerTreble::Brighter) ==
           "C:/mod/assets/sound-library/smooth/smooth_39_treble_plus_8db.wav");
    assert(muffler_variant_path(muffler, MufflerTreble::Brightest) ==
           "C:/mod/assets/sound-library/smooth/smooth_39_treble_plus_14db.wav");
    const std::filesystem::path truck = "C:/mod/assets/sound-library/truck_exhaust.wav";
    assert(muffler_variant_path(truck, MufflerTreble::Brightest) == truck);

    // A real engine-sim asset may have 24-bit samples; convert to PCM16.
    auto pcm24 = pcm16;
    pcm24[4] = 45;
    pcm24[32] = 3; // block alignment
    pcm24[34] = 24;
    pcm24[28] = 0xCC; pcm24[29] = 0x04; pcm24[30] = 2; // byte rate 132300
    pcm24[40] = 9;
    pcm24.resize(53);
    const std::array<std::uint8_t, 9> data24 = {
        0,0,0x80, 0,0,0, 0xFF,0xFF,0x7F
    };
    for (std::size_t i = 0; i < data24.size(); ++i) pcm24[44+i] = data24[i];
    const auto converted = parse_impulse_wav(pcm24);
    assert(converted.size() == 3);
    assert(converted[0] == -32768 && converted[1] == 0 && converted[2] == 32767);

    // Unsafe or unsupported assets fail quietly; no out-of-bounds reads.
    auto truncated = pcm16;
    truncated.pop_back();
    assert(parse_impulse_wav(truncated).empty());
    auto stereo = pcm16;
    stereo[22] = 2;
    assert(parse_impulse_wav(stereo).empty());
    auto wrongRate = pcm16;
    wrongRate[24] = 0x80;
    assert(parse_impulse_wav(wrongRate).empty());

    // Engine Simulator supplies an IR name relative to its sound library.
    // The native mod must not depend on Motor Town's process working directory.
    const std::filesystem::path script =
        "mods/MotorTownEngineSim/assets/dory_v8_prototype.mr";
    assert(impulse_wav_path(script.string(), "smooth/smooth_39.wav") ==
        std::filesystem::path(
            "mods/MotorTownEngineSim/assets/sound-library/smooth/smooth_39.wav"));
    const auto absolute = std::filesystem::current_path() / "absolute-impulse.wav";
    assert(impulse_wav_path(script.string(), absolute.string()) == absolute);
    assert(impulse_wav_path(script.string(), "").empty());

    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        const std::string packaged = "packaged:";
        if (argument.compare(0, packaged.size(), packaged) == 0) {
            // A response the mod ships: loadable, with samples the synthesizer
            // keeps, and no longer than Engine Simulator's own road muffler
            // (smooth_39.wav, 33705 samples), of which the brightened copies are.
            const auto samples = load_impulse_wav(argument.substr(packaged.size()));
            assert(usable_impulse_for_engine_sim(samples));
            assert(samples.size() > 20 && samples.size() <= 33705);
        }
        else {
            assert(load_impulse_wav(argument).size() > 100);
        }
    }
}
