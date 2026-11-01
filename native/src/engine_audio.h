#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace mtes {

struct EngineState {
    double rpm = 0;
    double throttle = 0;
    int gear = 0; // Motor Town: neutral 0, forward gears 1..
    bool ignition = false;
};

// Implemented by the actual Engine Simulator combustion/synthesizer library.
// No window, sound device, standalone process, or Unreal dependencies here.
class EngineBackend {
public:
    virtual ~EngineBackend() = default;
    virtual bool load(const std::string &script) = 0;
    virtual bool advance(double seconds, double rpm, double throttle, int gear) = 0;
    virtual std::size_t read(std::int16_t *dst, std::size_t frames) = 0;
    virtual void stop() noexcept = 0;
};

class EngineAudio final {
public:
    enum class UpdateStatus { Idle, InvalidState, LoadFailed, AdvanceFailed, Ready };
    enum class RenderStatus { Idle, InvalidState, PcmUnderrun, PcmSilent, Ready };
    explicit EngineAudio(std::unique_ptr<EngineBackend> backend);
    ~EngineAudio();

    EngineAudio(const EngineAudio &) = delete;
    EngineAudio &operator=(const EngineAudio &) = delete;

    bool update(const std::string &vehicle, const std::string &script,
        EngineState state, std::chrono::steady_clock::time_point when);
    std::size_t render(std::int16_t *dst, std::size_t frames,
        std::chrono::steady_clock::time_point when, double engineVolume = 1.0,
        const std::string &expectedVehicle = {});
    bool is_replacing_stock() const noexcept { return m_replacing.load(); }
    UpdateStatus update_status() const noexcept { return m_updateStatus.load(); }
    RenderStatus render_status() const noexcept { return m_renderStatus.load(); }
    void stop() noexcept;

private:
    void stop_locked() noexcept;

    std::unique_ptr<EngineBackend> m_backend;
    mutable std::mutex m_mutex;
    std::atomic<bool> m_replacing{false};
    std::atomic<UpdateStatus> m_updateStatus{UpdateStatus::Idle};
    std::atomic<RenderStatus> m_renderStatus{RenderStatus::Idle};
    bool m_active = false;
    std::string m_vehicle;
    std::string m_script;
    std::chrono::steady_clock::time_point m_lastUpdate{};
};

} // namespace mtes
