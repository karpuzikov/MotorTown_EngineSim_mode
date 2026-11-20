#pragma once

#include "game_audio.h"

#include <memory>
#include <optional>
#include <vector>

namespace mtes {

// A game-thread wrapper for one positively identified UAudioComponent from
// MTEngineSoundComponent.EngineAudioComponents / ExhaustAudioComponents.
// The Unreal implementation must check UObject validity before each access.
class EngineSoundGainEndpoint {
public:
    virtual ~EngineSoundGainEndpoint() = default;
    virtual std::optional<float> gain() const noexcept = 0;
    virtual bool set_gain(float value) noexcept = 0;
};

// Treat all engine and exhaust loops as ONE original engine sound. If any
// channel fails to mute, restore every surviving original immediately.
// This class does not discover, construct or modify arbitrary game objects.
class MotorTownStockEngineEmitters final : public StockEngineEmitter {
public:
    MotorTownStockEngineEmitters(
        std::vector<std::shared_ptr<EngineSoundGainEndpoint>> engine,
        std::vector<std::shared_ptr<EngineSoundGainEndpoint>> exhaust);
    ~MotorTownStockEngineEmitters() override { (void)restore(); }

    MotorTownStockEngineEmitters(const MotorTownStockEngineEmitters&) = delete;
    MotorTownStockEngineEmitters& operator=(const MotorTownStockEngineEmitters&) = delete;

    bool mute() override;
    bool restore() noexcept override;

private:
    std::vector<std::shared_ptr<EngineSoundGainEndpoint>> m_channels;
    std::vector<float> m_originalGains;
    bool m_muted = false;
    bool m_restorePending = false;
};

} // namespace mtes
