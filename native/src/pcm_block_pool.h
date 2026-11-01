#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace mtes {

// Four stable PCM buffers. Only the game thread reserves/writes slots;
// the audio thread releases them on completion without allocation or locking.
class PcmBlockPool final {
public:
    static constexpr std::size_t FramesPerBlock = 2205;
    static constexpr std::size_t BlockCount = 4;

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
