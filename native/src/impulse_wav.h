#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace mtes {

// Engine Simulator convolution accepts mono PCM16 at its 44.1 kHz render rate.
// Its script assets can also be 24-bit PCM; normalize without an audio device.
std::vector<std::int16_t> parse_impulse_wav(const std::vector<std::uint8_t> &bytes);
std::filesystem::path impulse_wav_path(const std::string &script,
    const std::string &filename);
std::vector<std::int16_t> load_impulse_wav(const std::string &path);
bool usable_impulse_for_engine_sim(const std::vector<std::int16_t> &samples);

} // namespace mtes
