#pragma once

#include <algorithm>
#include <cmath>
#include <utility>

namespace mtes {

// Where and how loud Motor Town would play its stock engine sound right now,
// computed on the game thread from the stock AudioComponent, its attenuation
// settings and the camera. Native XAudio2 output bypasses Unreal's mixer, so
// it applies this itself.
struct SpatialMix {
    double gain = 1.0;      // stock volume multipliers x distance attenuation
    double pan = 0.0;       // -1 hard left .. +1 hard right, camera-relative
    double lowpass_hz = 0;  // distance low-pass cutoff; 0 = none
};

// Unreal's default 3D panning law: equal power, so a centred sound plays at
// -3 dB per side.
inline std::pair<float, float> equal_power_gains(const SpatialMix& mix, double volume) {
    const double pan = std::clamp(std::isfinite(mix.pan) ? mix.pan : 0.0, -1.0, 1.0);
    const double gain = std::max(0.0, std::isfinite(mix.gain) ? mix.gain : 0.0) *
        std::max(0.0, std::isfinite(volume) ? volume : 0.0);
    const double angle = (pan + 1.0) * 0.25 * 3.14159265358979323846;
    return {static_cast<float>(gain * std::cos(angle)), static_cast<float>(gain * std::sin(angle))};
}

// XAudio2 state-variable low-pass "Frequency" = 2 sin(pi f / fs); 1 = open.
inline float xaudio2_lowpass_frequency(double hz, double sampleRate = 44100.0) {
    if (!std::isfinite(hz) || hz <= 0 || hz >= sampleRate / 6.0) return 1.0f;
    return static_cast<float>(std::min(1.0, 2.0 * std::sin(3.14159265358979323846 * hz / sampleRate)));
}

} // namespace mtes
