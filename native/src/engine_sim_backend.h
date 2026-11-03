#pragma once

#include "engine_audio.h"

#include <memory>

namespace mtes {

// Concrete EngineBackend powered by Engine Simulator's simulation and audio
// libraries, without its Delta Studio window or desktop sound output.
std::unique_ptr<EngineBackend> make_engine_sim_backend();

} // namespace mtes
