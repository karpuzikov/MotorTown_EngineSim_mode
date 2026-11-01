# Live Engine Audio Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the Dory Wrecker's actual engine audio components while running, without altering any Motor Town sound.

**Architecture:** The existing SDK probe knows `EngineComponent.EngineSoundComponent` and its engine/exhaust arrays, but the supplied ignition-off discovery found no live owner. Expand the same read-only probe to inspect direct `EngineComponent` audio channels and print runtime RPM/ignition. Keep the most recent running snapshot when the engine stops so the report remains useful after game exit.

**Tech Stack:** UE4SS Lua exporter, existing deterministic Lua test harness and Python unittest wrapper.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- No C++ rebuild or modification to game audio properties.
- Never assume a direct intake, afterfire, or jake-brake channel is safe to mute; this is identification only.
- Do not inspect horns, tires, or other non-engine sound components.
- Retain the existing `MTES4` telemetry and game-settings behavior unchanged.

## Review Focus

- An absent `EngineSoundComponent` must not hide otherwise valid direct engine audio channels.
- Invalid direct objects or arrays must be labelled unavailable without raising errors.
- A late-created audio component must appear in the next 5-second snapshot.
- An engine-off snapshot must not overwrite a previously captured running report.
- Reports must clearly differentiate known idle/off state from observed running state.

---

### Task 1: Read-only direct engine channel inventory

**Files:** Modify `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`, `bridge/tests/telemetry_harness.lua`, and `bridge/tests/test_telemetry.py`.

**Interfaces:** Extend `sdk_audio_targets(vehicle)` to report the existing nested arrays alongside direct `EngineComponent.AudioComponent`, `IntakeAudioComponent`, `JakeBrakeAudioComponent`, and `AfterfireAudioComponents`, using the existing safe reflection helpers. No game writes.

- [x] Add failing harness tests for a missing nested owner with populated direct channels and for invalid direct entries.
- [x] Confirm the new tests fail for missing diagnostics.
- [x] Implement the minimal direct-channel read-only probe.
- [x] Run the targeted telemetry test suite green.

### Task 2: Preserve running state evidence

**Files:** Modify the same three files.

**Interfaces:** Extend `write_audio_targets(vehicle)` to annotate engine RPM/ignition; once a report is captured with ignition on and positive RPM, do not replace it with an off-state report for the same vehicle.

- [x] Add failing tests for active runtime state and for a later engine-off tick retaining the live snapshot.
- [x] Verify the expected failures, implement retention, then rerun the tests.
- [x] Run all bridge and native tests, check CRLF-aware whitespace, and commit only this diagnostic change to PR #1 (not a playable release).
