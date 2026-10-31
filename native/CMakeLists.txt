cmake_minimum_required(VERSION 3.18)

# Include this directory from a parent project that already defines the UE4SS
# target at the exact binary-compatible commit used by the game installation.
project(MotorTownEngineSim LANGUAGES CXX)

option(MTES_HEADLESS_SMOKE "Build only a Windows headless Engine Simulator PCM smoke test" OFF)

include(FetchContent)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

# Pin the known Engine Simulator fork. FetchContent places the checkout inside
# the build directory, so the compatibility patch never modifies a developer's
# source checkout or any installed Motor Town files.
FetchContent_Declare(mtes_engine_sim
    GIT_REPOSITORY https://github.com/karpuzikov/engine-sim.git
    GIT_TAG 85f7c3b959a908ed5232ede4f1a4ac7eafe6b630
    GIT_SUBMODULES_RECURSE TRUE)
FetchContent_GetProperties(mtes_engine_sim)
if(NOT mtes_engine_sim_POPULATED)
    FetchContent_Populate(mtes_engine_sim)
endif()

execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/patch_engine_sim_core.py"
            "${mtes_engine_sim_SOURCE_DIR}"
    RESULT_VARIABLE mtes_patch_result
    OUTPUT_VARIABLE mtes_patch_output
    ERROR_VARIABLE mtes_patch_error)
if(NOT mtes_patch_result EQUAL 0)
    message(FATAL_ERROR "Engine Simulator build source is unsupported:\n${mtes_patch_error}")
endif()

# Build simulation and script libraries only. The graphical desktop executable
# and DirectSound device are not part of this DLL.
set(DISCORD_ENABLED OFF CACHE BOOL "" FORCE)
set(PIRANHA_ENABLED ON CACHE BOOL "" FORCE)
set(DTV OFF CACHE BOOL "" FORCE)
add_subdirectory("${mtes_engine_sim_SOURCE_DIR}" "${mtes_engine_sim_BINARY_DIR}" EXCLUDE_FROM_ALL)

set(MTES_AUDIO_SOURCES
    src/engine_audio.cpp
    src/game_audio.cpp
    src/game_telemetry.cpp
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
