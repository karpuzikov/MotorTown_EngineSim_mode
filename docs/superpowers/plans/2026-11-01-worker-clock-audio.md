# Native Worker-Clock PCM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep genuine Engine Simulator engine PCM continuous across delayed Unreal/Lua telemetry ticks without weakening stock-sound safety.

**Architecture:** Add an explicit worker-clock pacing mode to the native pipeline, retaining the current packet-driven path for deterministic tests. The existing 20-ms native audio worker advances and queues PCM from the freshest validated telemetry snapshot even if its sequence is unchanged. Keep the Lua mute acknowledgment, per-frame identity checks, and focus/stale fail-open safeguards.

**Tech Stack:** C++20, UE4SS 3.0.1, XAudio2, Engine Simulator pinned commit `85f7c3b959a908ed5232ede4f1a4ac7eafe6b630`, Python unittest/C++ test executables.

**Spec:** `docs/superpowers/specs/2026-11-01-worker-clock-audio-design.md`

## Global Constraints

- Only the local player's identified stock engine/exhaust cue can be muted, and only after a fresh Lua ACK.
- Telemetry age remains bounded at 250 ms; background, ignition-off, vehicle switch, missing settings, or unsafe PCM must restore original audio.
- Preserve authored engine simulation frequency and the existing user's Windows build/SDK/UE4SS installation.
- Do not publish a playable release without an actual Motor Town test.

## Review Focus

- Duplicate sequence at 20-ms intervals: queue new PCM only on the native audio clock (Task 1).
- Replayed or stale telemetry: never restart PCM or retain stock mute (Task 1).
- Same sequence with changed/invalid engine volume or different vehicle: restore or rescope before rendering (Task 1).
- Foreground loss during a slow simulation: do not queue new PCM; restore stock independently of the Unreal update callback (Task 2).
- Failed Lua mute ACK, PCM shortfall, or backend stop: retain fail-open stock audio (Task 2).

---

### Task 1: Separate telemetry freshness from worker PCM pacing

**Files:** Modify `native/src/audio_pipeline.h`, `native/src/audio_pipeline.cpp`; test `native/tests/audio_pipeline_test.cpp`, `native/tests/test_audio_pipeline.py`.

**Interfaces:** Add `NativeAudioPipeline::Pacing { TelemetryPackets, WorkerClock }` to its public API, an optional constructor `Pacing` argument after the packet-frame count, and a private `Clock::time_point m_lastAudioTickAt`.

- [x] Add a failing C++ test with worker-clock mode and one telemetry sequence: priming at `t`, no second tick at `t+10ms`, PCM at `t+25ms` and `t+45ms`, followed by restoration on stale/invalid input. Check cumulative PCM is based on elapsed audio ticks, not sequence changes.
- [x] Run `python -m unittest native.tests.test_audio_pipeline -v` and confirm failure before implementation.
- [x] On `Pacing::WorkerClock`, gate PCM updates by 15 ms of elapsed wall clock, advance with the latest fresh telemetry even for duplicate sequences, and size PCM from the actual interval since the preceding audio tick. Preserve session/sequence high-water marks and all existing fail-open checks. Keep `TelemetryPackets` semantics unchanged.
- [x] Rerun the targeted C++ test until it passes.
- [x] Commit this standalone behavior and test (`0c5d925`).

### Task 2: Enable worker-clock mode in UE4SS and verify safe lifecycle

**Files:** Modify `native/src/dllmain.cpp`, possibly `native/src/audio_worker.cpp`; test `native/tests/audio_worker_test.cpp`, `native/tests/test_audio_worker.py`.

**Interfaces:** Construct the real `NativeAudioPipeline` using `Pacing::WorkerClock`; retain `NativeAudioWorker` current 20-ms `std::jthread` and COM ownership.

- [x] Add a failing native-worker regression for uninterrupted PCM on duplicated valid telemetry, then loss of focus during a slow advance, stale/ignition-off telemetry, and stock mute restoration.
- [x] Run targeted audio-worker tests and confirm their failure.
- [x] Wire explicit worker-clock mode into the DLL and preserve the existing eligibility callback for late frame rechecks; adjust worker pacing only if the test proves it necessary.
- [x] Run both targeted native suites, then all native and bridge suites; `git diff --check` (54 native, 124 bridge tests).
- [x] Commit integration and tests (`76b4cba`).

### Task 3: Real Windows combustion verification and dev handoff

**Files:** Modify `.github/workflows/native-headless-windows.yml` / `native/tests/headless_engine_smoke.cpp` only if needed for a genuine worker-clock integration probe. No game installation changes.

- [ ] Verify exact source and staged-tree SHA, publish a development commit to existing `feat/native-engine-audio` branch without merging PR #1.
- [ ] Run Windows genuine-synthesis stress, compare the 150-ms/186-ms producer results, and verify the packaged Dory asset test. If a stress failure remains, diagnose it before requesting a game build.
- [ ] Once tests support a development trial, give a single PowerShell 7 block that initializes all variables, updates `--ff-only`, builds the existing CMake tree, and runs `install-dev-test.ps1` with backups.
- [ ] Ask for an in-game Dory throttle/gear/minimize check and the UE4SS stage diagnostics. Keep public release blocked until that result is verified.
