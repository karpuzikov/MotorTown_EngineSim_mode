#include "pcm_block_pool.h"

#include <array>
#include <cassert>
#include <cstdint>

int main() {
    // A 67ms game tick requires ~2955 PCM16 samples in one queued packet.
    assert(mtes::PcmBlockPool::FramesPerBlock >= 3000);
    mtes::PcmBlockPool pool;
    std::array<std::int16_t, mtes::PcmBlockPool::FramesPerBlock> pcm{};
    pcm[0] = 42;
    pcm.back() = -42;

    assert(!pool.acquire(nullptr, pcm.size()));
    assert(!pool.acquire(pcm.data(), 0));
    assert(!pool.acquire(pcm.data(), pcm.size() + 1));

    std::array<mtes::PcmBlockPool::Block*, mtes::PcmBlockPool::BlockCount> blocks{};
    for (auto& block : blocks) {
        block = pool.acquire(pcm.data(), pcm.size());
        assert(block);
        assert(block->frames == pcm.size());
        assert(block->samples.front() == 42);
        assert(block->samples.back() == -42);
    }
    assert(!pool.acquire(pcm.data(), pcm.size()));

    pcm[0] = 99;
    assert(blocks[0]->samples.front() == 42); // source changes cannot corrupt queued data
    mtes::PcmBlockPool::release(blocks[0]);
    auto* reused = pool.acquire(pcm.data(), 16);
    assert(reused == blocks[0]);
    assert(reused->frames == 16);
    assert(reused->samples.front() == 99);
    assert(!pool.acquire(pcm.data(), 16)); // still exactly four held slots

    pool.reset(); // caller may reset only after the source voice is destroyed
    for (std::size_t i = 0; i < blocks.size(); ++i) {
        assert(pool.acquire(pcm.data(), 16));
    }
    assert(!pool.acquire(pcm.data(), 16));
}
