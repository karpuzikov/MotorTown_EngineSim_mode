cmake_minimum_required(VERSION 3.22)
project(MotorTownEngineSimUE4SS LANGUAGES CXX)

# The C++ mod must link the actual UE4SS build selected for the game. This
# parent does not download an arbitrary UE4SS release or install into a game.
set(MTES_UE4SS_SOURCE "" CACHE PATH "Epic-enabled, game-compatible RE-UE4SS source checkout")
get_filename_component(mtes_native_default "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(MTES_NATIVE_SOURCE "${mtes_native_default}" CACHE PATH "MotorTown native source checkout")

if(NOT EXISTS "${MTES_UE4SS_SOURCE}/CMakeLists.txt" OR
   NOT EXISTS "${MTES_UE4SS_SOURCE}/UE4SS/include/Mod/CppUserModBase.hpp")
    message(FATAL_ERROR
        "MTES_UE4SS_SOURCE must point to a fully initialized, game-compatible RE-UE4SS checkout. "
        "Link an Epic account to GitHub and initialize its submodules before building.")
endif()
if(NOT EXISTS "${MTES_NATIVE_SOURCE}/CMakeLists.txt")
    message(FATAL_ERROR "MTES_NATIVE_SOURCE must point to the MotorTown native source directory")
endif()

add_subdirectory("${MTES_UE4SS_SOURCE}" "${CMAKE_BINARY_DIR}/UE4SS")
if(NOT TARGET UE4SS)
    message(FATAL_ERROR "The selected UE4SS source did not define a UE4SS target")
endif()
# UE4SS's custom Shipping configuration has no matching vcpkg Boost config.
# Without an explicit mapping CMake arbitrarily picks DEBUG, importing a
# boost_*gd*.dll that cannot load with the game's release CRT. Apply only to
# third-party imported targets created within the native mod subtree.
set(CMAKE_MAP_IMPORTED_CONFIG_GAME__SHIPPING__WIN64 Release)
add_subdirectory("${MTES_NATIVE_SOURCE}" "${CMAKE_BINARY_DIR}/MotorTownEngineSim")
if(NOT TARGET MotorTownEngineSim)
    message(FATAL_ERROR "MotorTownEngineSim must be a shared library target")
endif()
get_target_property(mtes_mod_type MotorTownEngineSim TYPE)
if(NOT mtes_mod_type STREQUAL "SHARED_LIBRARY")
    message(FATAL_ERROR "MotorTownEngineSim must be a shared library target")
endif()
get_property(mtes_engine_sim_stage GLOBAL PROPERTY MTES_ENGINE_SIM_SOURCE_DIR)
if(NOT EXISTS "${mtes_engine_sim_stage}/es/engine_sim.mr" OR
   NOT EXISTS "${mtes_engine_sim_stage}/es/sound-library/smooth/smooth_39.wav")
    message(FATAL_ERROR "Pinned Engine Simulator script or V8 impulse-response assets are unavailable for staging")
endif()

# Stage a dev artifact for inspection. This does not touch Motor Town, enable
# a mod or claim procedural audio has been verified inside the game.
set_target_properties(MotorTownEngineSim PROPERTIES OUTPUT_NAME "main")
set(mtes_stage_mod "${CMAKE_BINARY_DIR}/dev-stage/ue4ss/Mods/MotorTownEngineSim")
set(mtes_stage "${mtes_stage_mod}/dlls")
set(mtes_bridge_source "${CMAKE_CURRENT_LIST_DIR}/../../bridge/UE4SS/Mods/MotorTownEngineSim")
# These are package resources from this checkout, independent of a fake
# native target used by the standalone parent CMake wiring test.
set(mtes_profile_source "${CMAKE_CURRENT_LIST_DIR}/../profiles")
# The Windows vcpkg triplet is dynamically linked. Engine Simulator's Boost
# imports (and their transitive vcpkg DLLs) must live next to main.dll for
# UE4SS's LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR to find them in-game. Keep this
# limited to the development package, not the game or global PATH.
set(MTES_VCPKG_RUNTIME_BIN "" CACHE PATH "DLL directory for the active vcpkg Windows triplet")
if(WIN32 AND NOT MTES_VCPKG_RUNTIME_BIN AND
   DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
    set(MTES_VCPKG_RUNTIME_BIN "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
endif()
set(mtes_runtime_copy_commands)
if(MTES_VCPKG_RUNTIME_BIN)
    if(NOT IS_DIRECTORY "${MTES_VCPKG_RUNTIME_BIN}")
        message(FATAL_ERROR "vcpkg runtime DLL directory missing: ${MTES_VCPKG_RUNTIME_BIN}")
    endif()
    file(GLOB mtes_runtime_dlls CONFIGURE_DEPENDS
        "${MTES_VCPKG_RUNTIME_BIN}/*.dll")
    if(WIN32 AND NOT mtes_runtime_dlls)
        message(FATAL_ERROR "No vcpkg runtime DLLs available to stage in ${MTES_VCPKG_RUNTIME_BIN}")
    endif()
    foreach(mtes_runtime_dll IN LISTS mtes_runtime_dlls)
        get_filename_component(mtes_runtime_name "${mtes_runtime_dll}" NAME)
        if(mtes_runtime_name STREQUAL "main.dll")
            message(FATAL_ERROR "Refusing to overwrite main.dll with a vcpkg runtime")
        endif()
        list(APPEND mtes_runtime_copy_commands
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${mtes_runtime_dll}" "${mtes_stage}/${mtes_runtime_name}")
    endforeach()
elseif(WIN32)
    message(FATAL_ERROR "Set MTES_VCPKG_RUNTIME_BIN to the active vcpkg triplet's bin directory")
endif()
file(GLOB mtes_profile_scripts CONFIGURE_DEPENDS
    "${mtes_profile_source}/es_*.mr" "${mtes_profile_source}/es_*.boost.json")
if(NOT mtes_profile_scripts)
    message(FATAL_ERROR "No Engine Simulator profiles in ${mtes_profile_source}")
endif()
add_custom_target(mtes-stage-dev ALL
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${mtes_stage}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "$<TARGET_FILE:MotorTownEngineSim>"
        "${mtes_stage}/main${CMAKE_SHARED_LIBRARY_SUFFIX}"
    ${mtes_runtime_copy_commands}
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${mtes_stage_mod}/Scripts"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_bridge_source}/Scripts/main.lua" "${mtes_stage_mod}/Scripts/main.lua"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_bridge_source}/enabled.txt" "${mtes_stage_mod}/enabled.txt"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_profile_source}/engine_profiles.tsv" "${mtes_stage_mod}/engine_profiles.tsv"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_profile_source}/engine_families.tsv" "${mtes_stage_mod}/engine_families.tsv"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_profile_source}/settings.ini" "${mtes_stage_mod}/settings.ini"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${mtes_stage_mod}/assets"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${mtes_profile_scripts}
        "${mtes_stage_mod}/assets/"
    # Profiles are self-contained engines; they need only the impulse responses.
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${mtes_engine_sim_stage}/es/sound-library" "${mtes_stage_mod}/assets/sound-library"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${mtes_engine_sim_stage}/es" "${mtes_stage_mod}/es"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${mtes_engine_sim_stage}/LICENSE" "${mtes_stage_mod}/ENGINE_SIM_LICENSE.txt"
    DEPENDS MotorTownEngineSim
    COMMENT "Stage development-only UE4SS module; do not install as an audio replacement"
    VERBATIM)
