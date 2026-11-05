#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace mtes {

// The 3D mix gain is applied by XAudio2 after the PCM is queued, and it
// exceeds 1 for a close vehicle (about 1.8 seen in game). A peak that passes
// full scale after the gain is hard-clipped by the device: a harsh crack on
// every peak. This bends only the peaks that would pass the knee after the
// gain, smoothly (tanh), so a close engine is full without clipping. At or
// under the knee the PCM is untouched.
inline constexpr double OutputLimiterKneeOfFullScale = 0.8;
inline constexpr double OutputLimiterCeilingOfFullScale = 0.999;

inline void limit_peaks_for_gain(std::int16_t* pcm, std::size_t frames, double outputGain) {
    if (!pcm || !(outputGain > OutputLimiterKneeOfFullScale)) return; // also NaN
    const double kneeInput = OutputLimiterKneeOfFullScale * 32768.0 / outputGain;
    const double ceilingInput = OutputLimiterCeilingOfFullScale * 32768.0 / outputGain;
    const double span = ceilingInput - kneeInput;
    for (std::size_t i = 0; i < frames; ++i) {
        const double magnitude = std::abs(static_cast<double>(pcm[i]));
        if (magnitude <= kneeInput) continue;
        const double limited = kneeInput + span * std::tanh((magnitude - kneeInput) / span);
        const auto rounded = static_cast<std::int16_t>(
            std::min(32767.0, std::floor(limited + 0.5)));
        pcm[i] = pcm[i] < 0 ? static_cast<std::int16_t>(-rounded) : rounded;
    }
}

} // namespace mtes
