cmake_minimum_required(VERSION 3.18)

# Include this directory from a parent project that already defines the UE4SS
# target at the exact binary-compatible commit used by the game installation.
project(MotorTownEngineSim LANGUAGES CXX)

add_library(MotorTownEngineSim SHARED src/dllmain.cpp)
target_compile_features(MotorTownEngineSim PRIVATE cxx_std_20)
target_include_directories(MotorTownEngineSim PRIVATE src)
target_link_libraries(MotorTownEngineSim PRIVATE UE4SS)
