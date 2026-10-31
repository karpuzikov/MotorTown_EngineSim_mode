#include "impulse_wav.h"

#include <array>
#include <cassert>
#include <cstdint>
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

    for (int i = 1; i < argc; ++i) {
        assert(load_impulse_wav(argv[i]).size() > 100);
    }
}
