#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "mod_settings.h"

namespace mtes {

// Engine Simulator convolution accepts mono PCM16 at its 44.1 kHz render rate.
// Its script assets can also be 24-bit PCM; normalize without an audio device.
std::vector<std::int16_t> parse_impulse_wav(const std::vector<std::uint8_t> &bytes);
std::filesystem::path impulse_wav_path(const std::string &script,
    const std::string &filename);
// settings.ini "muffler": Engine Simulator's road muffler (smooth_39.wav, which the script library resolves into the
// mod's es/ folder) or one of its pre-brightened copies, which ship with the profiles in <script folder>/sound-library/smooth
// (pipeline/make_muffler_treble_variants.py). Any other response is returned unchanged.
std::filesystem::path muffler_variant_path(const std::filesystem::path &impulse, const std::string &script,
    MufflerTreble muffler);
std::vector<std::int16_t> load_impulse_wav(const std::string &path);
bool usable_impulse_for_engine_sim(const std::vector<std::int16_t> &samples);

} // namespace mtes
