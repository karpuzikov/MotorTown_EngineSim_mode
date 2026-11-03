#pragma once

#include "engine_audio.h"

#include <memory>

namespace mtes {

// Concrete EngineBackend powered by Engine Simulator's simulation and audio
// libraries, without its Delta Studio window or desktop sound output.
std::unique_ptr<EngineBackend> make_engine_sim_backend();

// Test switch (settings.ini exhaust_response = off): engines loaded after this
// play the raw physical source through a unit impulse instead of the exhaust.
void set_engine_sim_exhaust_response_enabled(bool enabled);

} // namespace mtes
