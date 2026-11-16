cmake_minimum_required(VERSION 3.18)

# Offline dynamometer and renderer for the generated engine scripts.
# Builds Engine Simulator's simulation and script libraries only.
project(MotorTownEngineSimDyno LANGUAGES CXX)

include(FetchContent)
# Fork branch feat/physical-exhaust-sound: the original fixed 1.9 kHz input
# anti-alias cut, intake supply pressure, physically based exhaust sound,
# two-stroke lobes and sparks per cycle.
FetchContent_Declare(motor_town_engine_sim_core
    GIT_REPOSITORY https://github.com/karpuzikov/engine-sim.git
    GIT_TAG 5cb969c5f7bf0f638eed32d4c07f1d848247c467
    GIT_SUBMODULES_RECURSE TRUE)
FetchContent_GetProperties(motor_town_engine_sim_core)
if(NOT motor_town_engine_sim_core_POPULATED)
    FetchContent_Populate(motor_town_engine_sim_core)
endif()
set(core "${motor_town_engine_sim_core_SOURCE_DIR}")

# Boost 1.80+ removed path::is_complete(), which Piranha still calls.
file(READ "${core}/dependencies/submodules/piranha/src/path.cpp" piranha_path)
string(REPLACE "m_path->is_complete()" "m_path->is_absolute()" piranha_path "${piranha_path}")
file(WRITE "${core}/dependencies/submodules/piranha/src/path.cpp" "${piranha_path}")

set(DISCORD_ENABLED OFF CACHE BOOL "" FORCE)
set(PIRANHA_ENABLED ON CACHE BOOL "" FORCE)
set(DTV OFF CACHE BOOL "" FORCE)
add_subdirectory("${core}" "${motor_town_engine_sim_core_BINARY_DIR}" EXCLUDE_FROM_ALL)

add_executable(motor_town_engine_sim_dyno
    motor_town_engine_sim_dyno.cpp
    ../../native/src/impulse_wav.cpp)
target_compile_features(motor_town_engine_sim_dyno PRIVATE cxx_std_20)
target_include_directories(motor_town_engine_sim_dyno PRIVATE
    ../../native/src
    "${core}/include"
    "${core}/scripting/include"
    "${core}/dependencies/submodules")
target_link_libraries(motor_town_engine_sim_dyno PRIVATE engine-sim engine-sim-script-interpreter)
set_property(GLOBAL PROPERTY MOTOR_TOWN_ENGINE_SIM_CORE_DIR "${core}")
