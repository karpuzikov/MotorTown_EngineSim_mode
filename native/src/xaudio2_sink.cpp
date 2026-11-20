#include "xaudio2_sink.h"
#include "output_limiter.h"
#include "pcm_block_pool.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>
#include <xaudio2.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

namespace mtes {

struct XAudio2Sink::Impl final : IXAudio2VoiceCallback {
    PcmBlockPool pool;
    IXAudio2* engine = nullptr;
    IXAudio2MasteringVoice* master = nullptr;
    IXAudio2SourceVoice* source = nullptr;
    UINT32 outputChannels = 0;
    float appliedLeft = -1.0f, appliedRight = -1.0f, appliedFilter = -1.0f;
    // The loudest gain the output matrix gives the queued PCM (output_limiter.h).
    float peakOutputGain = 1.0f;
    std::atomic<bool> failed{false};
    // Frames submitted since this voice was created; the voice reports how
    // many it has played (SamplesPlayed), the difference is the queued lead.
    // SamplesPlayed counts from the voice's last Start (or end-of-stream
    // buffer); this sink starts the voice once, never stops it before
    // DestroyVoice and never sets XAUDIO2_END_OF_STREAM, so it only grows.
    std::atomic<std::uint64_t> framesSubmitted{0};

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
        XAUDIO2_VOICE_DETAILS details{};
        master->GetVoiceDetails(&details);
        outputChannels = details.InputChannels;
        if (outputChannels == 0 || outputChannels > XAUDIO2_MAX_AUDIO_CHANNELS) return false;

        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM;
        format.nChannels = 1;
        format.nSamplesPerSec = 44100;
        format.wBitsPerSample = 16;
        format.nBlockAlign = sizeof(std::int16_t);
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        return SUCCEEDED(engine->CreateSourceVoice(
            &source, &format, XAUDIO2_VOICE_USEFILTER, XAUDIO2_DEFAULT_FREQ_RATIO, this));
    }

    // Equal-power pan onto front left/right (mono output: summed power).
    void apply(const SpatialMix& mix, double volume) noexcept {
        if (!source) return;
        const auto [left, right] = equal_power_gains(mix, volume);
        // (std::max): Windows.h defines max/min macros unless NOMINMAX is set.
        peakOutputGain = outputChannels == 1 ? std::sqrt(left * left + right * right)
                                             : (std::max)(left, right);
        if (std::abs(left - appliedLeft) > 0.0005f || std::abs(right - appliedRight) > 0.0005f) {
            std::vector<float> matrix(outputChannels, 0.0f);
            if (outputChannels == 1) matrix[0] = std::sqrt(left * left + right * right);
            else { matrix[0] = left; matrix[1] = right; }
            if (SUCCEEDED(source->SetOutputMatrix(master, 1, outputChannels, matrix.data()))) {
                appliedLeft = left;
                appliedRight = right;
            }
        }
        const float frequency = xaudio2_lowpass_frequency(mix.lowpass_hz);
        if (std::abs(frequency - appliedFilter) > 0.0005f) {
            XAUDIO2_FILTER_PARAMETERS filter{LowPassFilter, frequency, 1.0f};
            if (SUCCEEDED(source->SetFilterParameters(&filter))) appliedFilter = frequency;
        }
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
        m_impl->apply(m_mix, m_volume); // before any PCM becomes audible
    }
    if (m_impl->failed.load(std::memory_order_acquire)) return false;

    auto* block = m_impl->pool.acquire(pcm, frames);
    if (!block) return false;
    limit_peaks_for_gain(block->samples.data(), frames, m_impl->peakOutputGain);
    XAUDIO2_BUFFER packet{};
    packet.AudioBytes = static_cast<UINT32>(frames * sizeof(std::int16_t));
    packet.pAudioData = reinterpret_cast<const BYTE*>(block->samples.data());
    packet.pContext = block;
    if (FAILED(m_impl->source->SubmitSourceBuffer(&packet))) {
        PcmBlockPool::release(block);
        return false;
    }
    m_impl->framesSubmitted.fetch_add(frames, std::memory_order_release);
    return true;
}

std::size_t XAudio2Sink::queued_frames() const noexcept {
    if (!m_impl || !m_impl->source) return 0;
    XAUDIO2_VOICE_STATE state{};
    m_impl->source->GetState(&state);
    const auto submitted = m_impl->framesSubmitted.load(std::memory_order_acquire);
    return static_cast<std::size_t>(submitted - (std::min<std::uint64_t>)(submitted, state.SamplesPlayed));
}

bool XAudio2Sink::start() {
    return m_impl && !m_impl->failed.load(std::memory_order_acquire) &&
        SUCCEEDED(m_impl->source->Start(0));
}

void XAudio2Sink::stop() noexcept { m_impl.reset(); }

void XAudio2Sink::set_mix(const SpatialMix& mix) noexcept {
    m_mix = mix;
    if (m_impl) m_impl->apply(m_mix, m_volume);
}

void XAudio2Sink::set_output_volume(double volume) noexcept {
    m_volume = std::isfinite(volume) ? std::clamp(volume, 0.0, 4.0) : 1.0;
    if (m_impl) m_impl->apply(m_mix, m_volume);
}

} // namespace mtes

#else

namespace mtes {

struct XAudio2Sink::Impl {};
XAudio2Sink::XAudio2Sink() = default;
XAudio2Sink::~XAudio2Sink() = default;
bool XAudio2Sink::queue(const std::int16_t*, std::size_t) { return false; }
bool XAudio2Sink::start() { return false; }
void XAudio2Sink::stop() noexcept {}
std::size_t XAudio2Sink::queued_frames() const noexcept { return 0; }
void XAudio2Sink::set_mix(const SpatialMix& mix) noexcept { m_mix = mix; }
void XAudio2Sink::set_output_volume(double volume) noexcept { m_volume = volume; }

} // namespace mtes

#endif
