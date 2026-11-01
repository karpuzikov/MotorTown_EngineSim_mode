#include "xaudio2_sink.h"
#include "pcm_block_pool.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>
#include <xaudio2.h>

#include <atomic>

namespace mtes {

struct XAudio2Sink::Impl final : IXAudio2VoiceCallback {
    PcmBlockPool pool;
    IXAudio2* engine = nullptr;
    IXAudio2MasteringVoice* master = nullptr;
    IXAudio2SourceVoice* source = nullptr;
    std::atomic<bool> failed{false};

    ~Impl() {
        if (source) {
            (void)source->Stop(0);
            // DestroyVoice joins audio processing before the pool is reset.
            // No callback can still access our PCM after this returns.
            source->DestroyVoice();
        }
        if (master) master->DestroyVoice();
        if (engine) engine->Release();
        pool.reset();
    }

    bool open() {
        if (FAILED(XAudio2Create(&engine, 0, XAUDIO2_DEFAULT_PROCESSOR))) return false;
        if (FAILED(engine->CreateMasteringVoice(&master))) return false;

        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM;
        format.nChannels = 1;
        format.nSamplesPerSec = 44100;
        format.wBitsPerSample = 16;
        format.nBlockAlign = sizeof(std::int16_t);
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        return SUCCEEDED(engine->CreateSourceVoice(
            &source, &format, 0, XAUDIO2_DEFAULT_FREQ_RATIO, this));
    }

    void __stdcall OnVoiceProcessingPassStart(UINT32) noexcept override {}
    void __stdcall OnVoiceProcessingPassEnd() noexcept override {}
    void __stdcall OnStreamEnd() noexcept override {}
    void __stdcall OnBufferStart(void*) noexcept override {}
    void __stdcall OnBufferEnd(void* context) noexcept override {
        PcmBlockPool::release(static_cast<PcmBlockPool::Block*>(context));
    }
    void __stdcall OnLoopEnd(void*) noexcept override {}
    void __stdcall OnVoiceError(void*, HRESULT) noexcept override {
        failed.store(true, std::memory_order_release);
    }
};

XAudio2Sink::XAudio2Sink() = default;
XAudio2Sink::~XAudio2Sink() { stop(); }

bool XAudio2Sink::queue(const std::int16_t* pcm, std::size_t frames) {
    if (!pcm || frames == 0 || frames > PcmBlockPool::FramesPerBlock) return false;
    if (!m_impl) {
        auto candidate = std::make_unique<Impl>();
        if (!candidate->open()) return false;
        m_impl = std::move(candidate);
    }
    if (m_impl->failed.load(std::memory_order_acquire)) return false;

    auto* block = m_impl->pool.acquire(pcm, frames);
    if (!block) return false;
    XAUDIO2_BUFFER packet{};
    packet.AudioBytes = static_cast<UINT32>(frames * sizeof(std::int16_t));
    packet.pAudioData = reinterpret_cast<const BYTE*>(block->samples.data());
    packet.pContext = block;
    if (FAILED(m_impl->source->SubmitSourceBuffer(&packet))) {
        PcmBlockPool::release(block);
        return false;
    }
    return true;
}

bool XAudio2Sink::start() {
    return m_impl && !m_impl->failed.load(std::memory_order_acquire) &&
        SUCCEEDED(m_impl->source->Start(0));
}

void XAudio2Sink::stop() noexcept { m_impl.reset(); }

} // namespace mtes

#else

namespace mtes {

struct XAudio2Sink::Impl {};
XAudio2Sink::XAudio2Sink() = default;
XAudio2Sink::~XAudio2Sink() = default;
bool XAudio2Sink::queue(const std::int16_t*, std::size_t) { return false; }
bool XAudio2Sink::start() { return false; }
void XAudio2Sink::stop() noexcept {}

} // namespace mtes

#endif
