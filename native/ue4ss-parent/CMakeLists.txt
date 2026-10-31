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
add_subdirectory("${MTES_NATIVE_SOURCE}" "${CMAKE_BINARY_DIR}/MotorTownEngineSim")
if(NOT TARGET MotorTownEngineSim)
    message(FATAL_ERROR "MotorTownEngineSim must be a shared library target")
endif()
get_target_property(mtes_mod_type MotorTownEngineSim TYPE)
if(NOT mtes_mod_type STREQUAL "SHARED_LIBRARY")
    message(FATAL_ERROR "MotorTownEngineSim must be a shared library target")
endif()

# Stage a dev artifact for inspection. This does not touch Motor Town, enable
# a mod or claim procedural audio has been verified inside the game.
set_target_properties(MotorTownEngineSim PROPERTIES OUTPUT_NAME "main")
set(mtes_stage "${CMAKE_BINARY_DIR}/dev-stage/ue4ss/Mods/MotorTownEngineSim/dlls")
add_custom_target(mtes-stage-dev ALL
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${mtes_stage}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "$<TARGET_FILE:MotorTownEngineSim>"
        "${mtes_stage}/main${CMAKE_SHARED_LIBRARY_SUFFIX}"
    DEPENDS MotorTownEngineSim
    COMMENT "Stage development-only UE4SS module; do not install as an audio replacement"
    VERBATIM)
