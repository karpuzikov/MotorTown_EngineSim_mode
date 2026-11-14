#pragma once

#include "engine_audio.h"
#include "mod_settings.h"

#include <memory>

namespace mtes {

// Concrete EngineBackend powered by Engine Simulator's simulation and audio
// libraries, without its Delta Studio window or desktop sound output.
std::unique_ptr<EngineBackend> make_engine_sim_backend();

// settings.ini "muffler" for every engine loaded after the call (player and traffic).
void set_engine_sim_muffler(MufflerTreble muffler) noexcept;

} // namespace mtes
