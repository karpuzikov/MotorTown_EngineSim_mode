#include "stock_engine_emitters.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace mtes {

MotorTownStockEngineEmitters::MotorTownStockEngineEmitters(
    std::vector<std::shared_ptr<EngineSoundGainEndpoint>> engine,
    std::vector<std::shared_ptr<EngineSoundGainEndpoint>> exhaust) {
    const auto append_unique = [this](const auto& group) {
        for (const auto& channel : group) {
            if (std::find(m_channels.begin(), m_channels.end(), channel) == m_channels.end()) {
                m_channels.push_back(channel);
            }
        }
    };
    append_unique(engine);
    append_unique(exhaust);
}

bool MotorTownStockEngineEmitters::mute() {
    if (m_channels.empty() || m_restorePending) return false;
    // Snapshot every original gain before changing any channel; otherwise a
    // failed second channel could leave the first muted with no safe fallback.
    if (!m_muted) {
        std::vector<float> originals;
        originals.reserve(m_channels.size());
        for (const auto& channel : m_channels) {
            const auto gain = channel ? channel->gain() : std::nullopt;
            if (!gain || !std::isfinite(*gain) || *gain < 0.0f) return false;
            originals.push_back(*gain);
        }
        m_originalGains = std::move(originals);
        m_muted = true;
    }
    for (const auto& channel : m_channels) {
        if (!channel || !channel->gain() || !channel->set_gain(0.0f)) {
            (void)restore();
            return false;
        }
    }
    return true;
}

bool MotorTownStockEngineEmitters::restore() noexcept {
    if (!m_muted) return true;
    bool allRestored = true;
    for (std::size_t i = 0; i < m_channels.size(); ++i) {
        // A temporarily unavailable object or failed Unreal setter must not
        // discard the only saved gain needed to recover from mute.
        if (!m_channels[i] || !m_channels[i]->gain() ||
            !m_channels[i]->set_gain(m_originalGains[i])) allRestored = false;
    }
    m_restorePending = !allRestored;
    if (allRestored) {
        m_originalGains.clear();
        m_muted = false;
    }
    return allRestored;
}

} // namespace mtes
