# Native Motor Town Mod Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a downloadable, audio-only in-process Motor Town mod that replaces stock engine sounds with vehicle-matched Engine Simulator audio.

**Architecture:** A native UE4SS module captures game telemetry and injects headless simulated PCM into Unreal vehicle audio. The Lua exporter remains a temporary read-only discovery tool until native hooks are verified.

**Tech Stack:** C++20, UE4SS native mod ABI, Unreal audio interfaces, Engine Simulator MIT source, Python and Lua regression harness, Windows build/release automation.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- No separate Engine Simulator executable, UI, extra user actions or manual engine selection.
- Preserve all non-engine game sounds and respect in-game Engine Volume.
- Preserve original game files and other UE4SS mods; restore on failures.
- No claim of working sound replacement without Windows game validation.

## Review Focus

- Missing or late-loaded EngineComponent must not crash or invent RPM; test in task 1.
- Large unrelated physics-component inventory must not hide engine data; test in task 1.
- Changing vehicles must refresh engine and gear mappings; test in task 3.
- An audio-render failure must restore stock audio, not cause silence or double playback; test in task 4.
- Engine Volume 0 must mute only replacement engine audio; test in task 4.

---

### Task 1: Reliable game telemetry discovery (first deliverable)

**Files:**
- Modify: `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`
- Modify: `bridge/tests/telemetry_harness.lua`
- Modify: `bridge/tests/test_telemetry.py`
- Modify: `bridge/README.md`

**Interfaces:**
- Produces: bounded diagnostic snapshots exposing engine, gear and audio metadata; unchanged v1 audio telemetry packet.
- Consumes: UE4SS reflection and the existing test harness.

- [ ] Write Lua-harness regression tests for engine-first enumeration under a deep object graph, discovered gear and prioritized sound metadata.
- [ ] Run them and observe failures for missing behavior.
- [ ] Add priority ordering and bounded, relevant diagnostic inventory; instrument gear without changing stock sounds.
- [ ] Run targeted Lua boundary tests and complete test suite; confirm no regressions.
- [ ] Commit the implementation separately from the future native release.

### Task 2: Native UE4SS startup foundation

**Files:**
- Create: `native/CMakeLists.txt`, `native/src/dllmain.cpp`, `native/tests/test_native_mod.py`

**Interfaces:**
- Produces: `start_mod`/`uninstall_mod` UE4SS ABI and no-window initialization; runtime logs.
- Consumes: installed UE4SS with matching C++ SDK.

- [ ] Write export/metadata and no-companion-process tests; verify failures.
- [ ] Implement minimal C++ mod startup with safe `on_unreal_init` and shutdown.
- [ ] Validate ABI through Windows build and in-game load before advancing.
- [ ] Commit native foundation, keeping it development-only.

### Task 3: Headless sound engine and matching

**Files:**
- Create: `native/src/engine_audio.*`, `native/src/vehicle_profile.*`, `native/tests/test_engine_audio.*`

**Interfaces:**
- Produces: thread-safe PCM stream for Unreal and current vehicle profile selection.
- Consumes: verified game telemetry, genuine Engine Simulator simulation and scripts.

- [ ] Test engine-profile changes, stale telemetry and audio buffer underflow.
- [ ] Extract/link simulation core without its Delta Studio graphics window.
- [ ] Verify engine profile compatibility and realtime audio timing in Windows.
- [ ] Commit after integration tests pass.

### Task 4: Unreal audio ownership and replacement

**Files:**
- Create: `native/src/game_audio.*`, `native/tests/test_game_audio.*`

**Interfaces:**
- Produces: in-game local-player sound component bound to Engine Volume, stock-audio fallback.
- Consumes: headless PCM and verified game sound-component identities.

- [ ] Test restoration, volume/mute and switching from stock to replacement.
- [ ] Attach procedural audio to local vehicle and isolate original engine emitters.
- [ ] Verify in-game volume and other sound categories across vehicles.
- [ ] Commit after game playback verification.

### Task 5: Distributable mod release

**Files:**
- Create: `native/installer/`, `native/release/` and packaging tests.
- Modify: `README.md` and remove legacy process requirements from the native install path.

**Interfaces:**
- Produces: public release archive and one-click installer for Windows, without end-user compilation.
- Consumes: fully tested native mod and profile resources.

- [ ] Test install/uninstall, preserved mods, unknown game paths and version mismatch.
- [ ] Build and package signed or hash-verified Windows artifacts.
- [ ] Validate on a fresh Windows Motor Town installation and multiple engines.
- [ ] Publish a normal, non-draft GitHub release only after verified.
