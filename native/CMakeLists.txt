cmake_minimum_required(VERSION 3.18)

# Include this directory from a parent project that already defines the UE4SS
# target at the exact binary-compatible commit used by the game installation.
project(MotorTownEngineSim LANGUAGES CXX)

option(MTES_HEADLESS_SMOKE "Build only a Windows headless Engine Simulator PCM smoke test" OFF)

include(FetchContent)
# The karpuzikov/engine-sim fork (branch feat/physical-exhaust-sound) carries
# the lifetime fixes this build used to patch in, plus physically based
# exhaust sound, intake boost and two-stroke support used by the real-spec
# profiles. FetchContent keeps the checkout inside the build directory.
set(motor_town_engine_sim_core_commit d88514f1328132f97cce789f1ee227ac0681d95d)
# One checkout per pinned commit: the Piranha fix below edits the checkout,
# so moving an existing one to another commit makes Git refuse (local changes).
string(SUBSTRING "${motor_town_engine_sim_core_commit}" 0 7 motor_town_engine_sim_core_short)
FetchContent_Declare(mtes_engine_sim
    GIT_REPOSITORY https://github.com/karpuzikov/engine-sim.git
    GIT_TAG ${motor_town_engine_sim_core_commit}
    GIT_SUBMODULES_RECURSE TRUE
    SOURCE_DIR "${FETCHCONTENT_BASE_DIR}/mtes_engine_sim-${motor_town_engine_sim_core_short}-src")
FetchContent_GetProperties(mtes_engine_sim)
if(NOT mtes_engine_sim_POPULATED)
    FetchContent_Populate(mtes_engine_sim)
endif()
# The enclosing UE4SS packaging target needs this location after returning
# from add_subdirectory(); ordinary child-scope variables do not propagate.
set_property(GLOBAL PROPERTY MTES_ENGINE_SIM_SOURCE_DIR "${mtes_engine_sim_SOURCE_DIR}")

# Boost 1.80+ removed path::is_complete(), which the Piranha submodule calls.
set(motor_town_engine_sim_piranha_path "${mtes_engine_sim_SOURCE_DIR}/dependencies/submodules/piranha/src/path.cpp")
file(READ "${motor_town_engine_sim_piranha_path}" motor_town_engine_sim_piranha_source)
string(REPLACE "m_path->is_complete()" "m_path->is_absolute()"
    motor_town_engine_sim_piranha_source "${motor_town_engine_sim_piranha_source}")
file(WRITE "${motor_town_engine_sim_piranha_path}" "${motor_town_engine_sim_piranha_source}")

# Build simulation and script libraries only. The graphical desktop executable
# and DirectSound device are not part of this DLL.
set(DISCORD_ENABLED OFF CACHE BOOL "" FORCE)
set(PIRANHA_ENABLED ON CACHE BOOL "" FORCE)
set(DTV OFF CACHE BOOL "" FORCE)
add_subdirectory("${mtes_engine_sim_SOURCE_DIR}" "${mtes_engine_sim_BINARY_DIR}" EXCLUDE_FROM_ALL)

set(MTES_AUDIO_SOURCES
    src/audio_pipeline.cpp
    src/audio_worker.cpp
    src/engine_audio.cpp
    src/game_audio.cpp
    src/stock_engine_emitters.cpp
    src/lua_mute_lease.cpp
    src/pcm_block_pool.cpp
    src/xaudio2_sink.cpp
    src/game_telemetry.cpp
    src/vehicle_profile.cpp
    src/traffic_engine_voices.cpp
    src/impulse_wav.cpp
    src/engine_sim_backend.cpp)

if(MTES_HEADLESS_SMOKE)
    add_executable(mtes-headless-smoke
        tests/headless_engine_smoke.cpp
        ${MTES_AUDIO_SOURCES})
    set(mtes_target mtes-headless-smoke)
else()
    add_library(MotorTownEngineSim SHARED
        src/dllmain.cpp
        ${MTES_AUDIO_SOURCES})
    set(mtes_target MotorTownEngineSim)
    target_link_libraries(MotorTownEngineSim PRIVATE UE4SS)
endif()

target_compile_features(${mtes_target} PRIVATE cxx_std_20)
target_include_directories(${mtes_target} PRIVATE
    src
    "${mtes_engine_sim_SOURCE_DIR}/include"
    "${mtes_engine_sim_SOURCE_DIR}/scripting/include"
    "${mtes_engine_sim_SOURCE_DIR}/dependencies/submodules")
target_link_libraries(${mtes_target} PRIVATE
    engine-sim
    engine-sim-script-interpreter)
if(WIN32)
    target_link_libraries(${mtes_target} PRIVATE xaudio2 user32 ole32)
endif()
