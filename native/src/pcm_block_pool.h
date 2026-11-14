#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace mtes {

// Sixteen stable PCM buffers (four ran dry when a slow first frame queued
// 8192 frames at once: "XAudio2 PCM queue failed" in game). Only the game thread reserves/writes slots;
// the audio thread releases them on completion without allocation or locking.
class PcmBlockPool final {
public:
    // Covers a delayed UE4SS game tick (up to ~93 ms) without allocating
    // on the XAudio2 callback or silently truncating a PCM packet.
    static constexpr std::size_t FramesPerBlock = 4096;
    static constexpr std::size_t BlockCount = 16;

    struct Block {
        std::array<std::int16_t, FramesPerBlock> samples{};
        std::size_t frames = 0;
        std::atomic<bool> in_use{false};
    };

    Block* acquire(const std::int16_t* pcm, std::size_t frames) noexcept;
    static void release(Block* block) noexcept;
    // Safe only after the consuming device has stopped all callbacks.
    void reset() noexcept;

private:
    std::array<Block, BlockCount> m_blocks{};
};

} // namespace mtes
