#include "stock_engine_emitters.h"

#include <cassert>
#include <cmath>
#include <memory>
#include <optional>
#include <vector>

using namespace mtes;

struct Channel final : EngineSoundGainEndpoint {
    float current;
    bool alive = true;
    bool allowSet = true;
    int changes = 0;

    explicit Channel(float gain) : current(gain) {}
    std::optional<float> gain() const noexcept override {
        if (!alive) return std::nullopt;
        return current;
    }
    bool set_gain(float gain) noexcept override {
        if (!alive || !allowSet) return false;
        current = gain;
        ++changes;
        return true;
    }
};

int main() {
    auto engine = std::make_shared<Channel>(0.75f);
    auto exhaust = std::make_shared<Channel>(0.4f);
    auto horn = std::make_shared<Channel>(0.9f);

    // Only channels sourced from the SDK engine/exhaust fields are owned.
    MotorTownStockEngineEmitters stock({engine}, {exhaust});
    assert(stock.mute());
    assert(engine->current == 0.0f && exhaust->current == 0.0f);
    assert(horn->current == 0.9f);
    // The game may update these volume multipliers every tick.
    engine->current = 0.6f;
    assert(stock.mute());
    assert(engine->current == 0.0f);
    stock.restore();
    assert(engine->current == 0.75f && exhaust->current == 0.4f);
    assert(horn->current == 0.9f);

    // A failure halfway through the group must never leave partial muting.
    exhaust->allowSet = false;
    assert(!stock.mute());
    assert(engine->current == 0.75f && exhaust->current == 0.4f);
    exhaust->allowSet = true;
    assert(stock.restore());

    // Validate every target BEFORE changing any volume.
    exhaust->alive = false;
    const int priorChanges = engine->changes;
    assert(!stock.mute());
    assert(engine->changes == priorChanges);
    exhaust->alive = true;

    // If a UObject disappears during active replacement, restore survivors.
    assert(stock.mute());
    exhaust->alive = false;
    assert(!stock.restore());
    assert(engine->current == 0.75f);
    exhaust->alive = true;
    assert(stock.restore());
    assert(exhaust->current == 0.4f);

    // A missing owner, invalid gain or duplicated channel is not a license
    // to leave one original emitter playing over the synthetic engine.
    MotorTownStockEngineEmitters missing({}, {});
    assert(!missing.mute());
    MotorTownStockEngineEmitters invalid({engine}, {nullptr});
    assert(!invalid.mute());
    const int beforeDuplicate = engine->changes;
    MotorTownStockEngineEmitters duplicated({engine, engine}, {});
    assert(duplicated.mute());
    assert(engine->changes == beforeDuplicate + 1);
    duplicated.restore();
    assert(engine->current == 0.75f);
    engine->current = std::nanf("");
    assert(!duplicated.mute());

    // An adapter destroyed during game shutdown must not strand a live
    // vehicle's engine audio at zero volume.
    auto temporary = std::make_shared<Channel>(0.6f);
    {
        MotorTownStockEngineEmitters duringShutdown({temporary}, {});
        assert(duringShutdown.mute());
        assert(temporary->current == 0.0f);
    }
    assert(temporary->current == 0.6f);

    // A temporary accessor failure during restore must leave the saved
    // original value available for the next game tick to retry.
    auto transient = std::make_shared<Channel>(0.8f);
    MotorTownStockEngineEmitters retryable({transient}, {});
    assert(retryable.mute());
    transient->allowSet = false;
    assert(!retryable.restore());
    assert(transient->current == 0.0f);
    transient->allowSet = true;
    assert(retryable.restore());
    assert(transient->current == 0.8f);
}
