#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace mtes {

// A standing lead of sound in the output queue absorbs a late worker tick or
// a slow synthesizer batch. Making exactly the time that has passed (1:1) left
// only the 60 ms of silence the voice started with, and one late tick used it
// up for good: every later hiccup was a gap (in game 2026-11-04: five to eleven
// "PCM buffer underrun" within a second of each engine start).
inline constexpr std::size_t OutputLeadTargetFrames = 4410; // 100 ms at 44.1 kHz
inline constexpr double OutputLeadCorrectionPerTick = 0.5;

// Frames of sound to make this tick: the time elapsed since the previous tick
// plus half of the gap to the target lead (negative while the queue is ahead of
// the target, so the lead settles instead of growing). Never less than half the
// elapsed time, never more than maxFrames.
inline std::size_t frames_for_tick(std::size_t elapsedFrames, std::size_t queuedFrames,
    std::size_t maxFrames) {
    const double elapsed = static_cast<double>(elapsedFrames);
    const double gap = static_cast<double>(OutputLeadTargetFrames) - static_cast<double>(queuedFrames);
    const double wanted = std::max(0.5 * elapsed, elapsed + OutputLeadCorrectionPerTick * gap);
    return std::clamp<std::size_t>(static_cast<std::size_t>(std::lround(wanted)), 1, maxFrames);
}

} // namespace mtes
