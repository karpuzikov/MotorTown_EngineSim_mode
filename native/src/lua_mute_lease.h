#pragma once

#include "audio_pipeline.h"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace mtes {

// Game-thread stock emitter lease: Lua owns the real UAudioComponent and
// acknowledges a verified zero VolumeMultiplier. No ACK means no XAudio2.
// A heartbeat in each MTESM1 request and Lua's independent watchdog restore
// the original gain if the native module crashes or stops sending requests.
class LuaMuteLeaseEmitter final : public StockEngineEmitter {
public:
    LuaMuteLeaseEmitter(std::filesystem::path temp, std::string session,
        std::string vehicle, std::string asset);
    bool prepare() override;
    bool mute() override;
    bool restore() noexcept override;
    void advance(std::uint64_t sequence) noexcept;

private:
    std::filesystem::path m_request;
    std::filesystem::path m_ack;
    std::string m_session;
    std::string m_vehicleHex;
    std::string m_assetHex;
    std::string m_token;
    std::uint64_t m_sequence = 0;
    bool m_prepared = false;
    bool m_requested = false;
};

class LuaMuteLeaseLookup final : public StockEmitterLookup {
public:
    explicit LuaMuteLeaseLookup(std::filesystem::path temp);
    std::shared_ptr<StockEngineEmitter> stock_for(
        const GameTelemetrySample& sample) override;
    void cancel() noexcept;

private:
    std::filesystem::path m_temp;
    std::string m_session;
    std::string m_vehicle;
    std::string m_asset;
    std::shared_ptr<LuaMuteLeaseEmitter> m_current;
};

} // namespace mtes
