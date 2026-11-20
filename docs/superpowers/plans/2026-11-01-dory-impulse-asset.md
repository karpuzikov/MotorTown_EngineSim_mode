# Dory impulse-response asset implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) for tracking.

**Goal:** Supply the missing Dory V8 impulse-response WAV and make Engine Simulator load it from the installed mod.

**Architecture:** Add a profile-relative impulse path resolver, then copy the pinned WAV into the staged `assets/sound-library/` directory. Do not affect game audio until PCM and the existing mute lease are ready.

**Tech Stack:** C++20, CMake, Python unittest.

**Spec:** `docs/superpowers/specs/2026-11-01-dory-impulse-asset-design.md`

## Global Constraints

- The game, current directory, and other game sounds must remain untouched.
- Stage only the known GM LS `smooth/smooth_39.wav` impulse response.

## Review Focus

- An absolute WAV path is preserved.
- Empty paths do not point to a directory.
- The installed package contains the sound file with original bytes.
- A missing source impulse response stops CMake configuration.
- The engine's script-relative path works from arbitrary process working directories.

### Task 1: Resolve one profile-relative impulse response

**Files:** `native/src/impulse_wav.h`, `native/src/impulse_wav.cpp`, `native/src/engine_sim_backend.cpp`, `native/tests/impulse_wav_test.cpp`

- [x] Add a failing test asserting profile-relative IR lookup, preserving absolute paths and rejecting empty names.
- [x] Run `python -m unittest native.tests.test_impulse_wav -v` and confirm failure (missing `impulse_wav_path`).
- [x] Implement `std::filesystem::path impulse_wav_path(const std::string& script, const std::string& filename)` and use it in the backend's WAV loader.
- [x] Run the same test and confirm pass.

### Task 2: Stage the Dory sound asset

**Files:** `native/ue4ss-parent/CMakeLists.txt`, `native/tests/test_ue4ss_build_parent.py`

- [x] Add a failing stage test with a fixture at `assets/sound-library/smooth/smooth_39.wav`, asserting identical packaged file bytes.
- [x] Run with `/tmp/mtes-cmake/cmake/data/bin/cmake` and confirm missing staged WAV.
- [x] Add a fail-closed source-asset check and copy command, preserving source bytes; correct the installer requirement.
- [x] Run the stage test and all native/bridge unit tests (33 native/124 bridge; Windows smoke pending GitHub CI).
