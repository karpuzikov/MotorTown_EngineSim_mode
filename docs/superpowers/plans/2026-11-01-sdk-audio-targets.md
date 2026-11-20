# SDK-guided Motor Town Audio Targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify the actual local vehicle engine/exhaust emitters reliably, and prepare an atomic, reversible controller for those emitters before connecting in-game PCM playback.

**Architecture:** The already-installed UE4SS Lua probe reads only the exact fields verified in the user's November 1 Motor Town SDK; it never mutes audio. A portable C++ engine/exhaust emitter group will preserve and restore original channel gains, with fail-open behavior. Game playback and live UE4SS audio ownership remain unverified and disabled.

**Tech Stack:** UE4SS Lua, C++20, Python unittest, portable C++ integration tests.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- Do not commit or distribute the user's proprietary generated SDK dump.
- Never mute engine/exhaust before validated PCM is queued and Unreal playback is confirmed.
- Do not touch tire, horn, radio, ambient, or unrelated game sound components.
- Do not break legacy MTES1 or native MTES3 telemetry formats.
- The UE4SS module remains development-only, not a playable release.

## Review Focus

- An absent or late-loaded `EngineSoundComponent` must not crash the exporter.
- An invalid audio array element must not prevent live RPM/gear reporting.
- SDK audio fields must be visible even after reflection discovery exhausts its budget.
- Muting two engine/exhaust channels must roll back the first if the second fails.
- Game-authored volume updates during replacement must be muted again without losing the saved original level.

---

### Task 1: SDK-targeted, read-only sound inventory

**Files:**
- Modify: `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`
- Modify: `bridge/tests/telemetry_harness.lua`
- Modify: `bridge/tests/test_telemetry.py`

**Interfaces:**
- Consumes: `EngineComponent.EngineSoundComponent` and its `EngineAudioComponents`/`ExhaustAudioComponents` TArrays, verified in the user's SDK.
- Produces: a bounded `SDK engine audio targets:` section in `MotorTownEngineSim_discovery.txt`, independent of generic reflection budgets.

- [x] Add real-exporter tests for two identified emitters, missing audio objects, malformed audio elements and crowded reflection.
- [x] Run tests and witness expected absence of the new report section.
- [x] Implement bounded, read-only TArray iteration and component identity/volume logging on each discovery.
- [x] Run targeted and full bridge tests; keep existing packet ABI unchanged (95 tests, 15 skipped).
- [x] Commit this independent diagnostics milestone (`f8c76b3`).

### Task 2: Fail-open multi-emitter audio ownership

**Files:**
- Create: `native/src/stock_engine_emitters.h`
- Create: `native/src/stock_engine_emitters.cpp`
- Create: `native/tests/stock_engine_emitters_test.cpp`
- Create: `native/tests/test_stock_engine_emitters.py`
- Modify: `native/src/game_audio.cpp`
- Modify: `native/tests/game_audio_test.cpp`
- Modify: `native/CMakeLists.txt`
- Modify: `native/README.md`

**Interfaces:**
- Consumes: stock engine/exhaust `UAudioComponent` wrappers implementing read/set gain with lifetime checks; game PCM gate in `GameAudioOutput`.
- Produces: `MotorTownStockEngineEmitters`, a reversible `StockEngineEmitter` owning multiple engine/exhaust endpoints only; repeat `mute()` reasserts zero without overwriting saved original gains.

- [x] Add failing executable tests for multi-channel mute/restore, partial failure rollback, missing/invalid targets and repeated muting.
- [x] Add failing handoff test for reapplying mute on each PCM packet after the game changes volume.
- [x] Implement the minimal group and packet-level mute maintenance, preserving stop-before-restore order.
- [x] Run the targeted tests and entire portable native suite (15 tests, 5 skipped).
- [x] Commit separately (`f7b3e72`), leaving actual Unreal sink and stock muting disabled in `dllmain.cpp`.

### Review fixes (follow-up)

- [x] Keep failed restoration snapshots owned by `GameAudioOutput` until later updates can retry.
- [x] Keep a bounded standalone audio-target snapshot refreshed every five seconds even with stable RPM mapping.
- [ ] Live Unreal stock-emitter update cadence and procedural playback remain **unverified**; no in-game muting is enabled.
