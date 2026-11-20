#pragma once

#include <algorithm>
#include <cmath>

namespace mtes {

// The starter cranks until the crank turns at this multiple of its own speed
// or half the game's rpm, whichever is higher; then the engine runs by itself.
// It cranks again only if the engine falls under this fraction of that speed
// (a one-cylinder engine's speed swings across a single threshold).
inline constexpr double StarterReleaseOfStarterSpeed = 1.2;
inline constexpr double StarterReleaseOfGameRpm = 0.5;
inline constexpr double StarterReengageFraction = 0.6;

inline double starter_release_rpm(double starterSpeedRpm, double targetRpm) {
    return std::max(StarterReleaseOfStarterSpeed * std::abs(starterSpeedRpm),
        StarterReleaseOfGameRpm * targetRpm);
}

// Whether the starter turns the crank this step. With the ignition on it is
// the loop above (cranks until the release speed, again under the re-engage
// fraction of it). Motor Town reports ~150 rpm while it cranks, and what its
// ignition flag says then is not certain: an unfired crank is the key turn
// before the engine has first caught, so it is heard whether or not the flag is
// up yet (it was silent: the sound was the engine catching, "binary on/off" in
// game). An engine that has run and is spinning down is not cranked, nor is
// one the game already turns faster than the starter could (a reload).
inline bool starter_engaged(bool wasEngaged, bool ignition, bool hasRun,
    double smoothedRpm, double targetRpm, double releaseRpm) {
    if (!ignition) return !hasRun && targetRpm < releaseRpm;
    return wasEngaged ? smoothedRpm < releaseRpm
                      : smoothedRpm < StarterReengageFraction * releaseRpm;
}

} // namespace mtes
