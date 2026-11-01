#include "pcm_block_pool.h"

#include <algorithm>

namespace mtes {

PcmBlockPool::Block* PcmBlockPool::acquire(
    const std::int16_t* pcm, std::size_t frames) noexcept {
    if (!pcm || frames == 0 || frames > FramesPerBlock) return nullptr;
    for (auto& block : m_blocks) {
        bool unused = false;
        if (!block.in_use.compare_exchange_strong(unused, true,
                std::memory_order_acq_rel)) continue;
        std::copy_n(pcm, frames, block.samples.begin());
        block.frames = frames;
        return &block;
    }
    return nullptr;
}

void PcmBlockPool::release(Block* block) noexcept {
    if (block) block->in_use.store(false, std::memory_order_release);
}

void PcmBlockPool::reset() noexcept {
    for (auto& block : m_blocks) {
        block.frames = 0;
        block.in_use.store(false, std::memory_order_release);
    }
}

} // namespace mtes
