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
    double maxRpm = 0; // the game's top rpm for this engine; 0 if unknown
};

// The crankshaft is turning: running, or cranked by the starter / spinning
// down with the ignition off (Motor Town reports ~150 RPM while cranking).
inline bool engine_turning(const EngineState &s) {
    return s.rpm >= 50 && s.rpm <= 25000; // false for NaN
}

// Implemented by the actual Engine Simulator combustion/synthesizer library.
// No window, sound device, standalone process, or Unreal dependencies here.
class EngineBackend {
public:
    virtual ~EngineBackend() = default;
    virtual bool load(const std::string &script) = 0;
    // The game's top rpm for the engine being played (0: unknown).
    virtual void set_game_max_rpm(double) {}
    // combustion false: the starter or momentum turns the engine unfired.
    virtual bool advance(double seconds, double rpm, double throttle, bool combustion) = 0;
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
    // Compiles the vehicle's engine while it stands still, so the starter's
    // first turn is heard instead of waiting for a script compile.
    bool preload(const std::string &vehicle, const std::string &script);
    std::size_t render(std::int16_t *dst, std::size_t frames,
        std::chrono::steady_clock::time_point when, double engineVolume = 1.0,
        const std::string &expectedVehicle = {});
    bool is_replacing_stock() const noexcept { return m_replacing.load(); }
    UpdateStatus update_status() const noexcept { return m_updateStatus.load(); }
    RenderStatus render_status() const noexcept { return m_renderStatus.load(); }
    void stop() noexcept;

private:
    void stop_locked() noexcept;
    bool load_locked(const std::string &vehicle, const std::string &script);

    std::unique_ptr<EngineBackend> m_backend;
    mutable std::mutex m_mutex;
    std::atomic<bool> m_replacing{false};
    std::atomic<UpdateStatus> m_updateStatus{UpdateStatus::Idle};
    std::atomic<RenderStatus> m_renderStatus{RenderStatus::Idle};
    bool m_active = false;
    std::string m_vehicle;
    std::string m_script;
    std::chrono::steady_clock::time_point m_lastUpdate{};
    bool m_advancedSinceLoad = false;
};

} // namespace mtes
