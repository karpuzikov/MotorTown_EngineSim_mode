# Dual-Cue Engine Audio Lease Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) for tracking.

**Goal:** Lease both verified Dory engine and intake cues, and expose the exact cause of acknowledgment loss.

**Architecture:** Lua owns two Unreal sound components under one native token, with all-or-nothing ACK and safe restoration. Native retains its strict fail-open protocol and records why a previously accepted ACK was rejected.

**Tech Stack:** UE4SS Lua, C++20, Python unittest, Lua test harness.

**Spec:** `docs/superpowers/specs/2026-11-01-dual-cue-audio-lease-design.md`

## Global Constraints

- No additional UI or processes; no unrelated sound changes; no release.
- Never replace stock while any verified target fails to mute.
- Avoid relaxing ACK security, worker timing, or CI thresholds as a shortcut.

## Review Focus

- A failed intake volume setter after successful engine mute restores the engine and never ACKs.
- An intake component/cue change revokes the old lease before replacement begins.
- Restore failure retains retry state and never leaves a positive ACK.
- Duplicate native requests cannot extend a stopped DLL's four-tick watchdog.
- Diagnostic reads and missing response files remain safe across the worker/game-thread boundary.

### Task 1: Verified dual-cue lease

**Files:** `bridge/tests/mute_lease_harness.lua`, `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`.

**Interfaces:** `mute_lease_tick(vehicle)` consumes current MTESM1 request and emits one MTESA1 only when both stock components are verified at zero gain. `restore_leased_engine(reason)` invalidates ACK first and restores every retained original gain.

- [ ] Add harness assertions for both components muted and restored, failed intake setter, intake cue/owner replacement and retained watchdog.
- [ ] Run `python -m unittest bridge.tests.test_mute_lease -v`, confirm regression fails against old Lua.
- [ ] Implement the minimal list-of-verified-channels lease, including reason-tagged Lua restoration logs.
- [ ] Run `python -m unittest bridge.tests.test_mute_lease -v`, confirm green.
- [ ] Commit this task after verifying the bridge suite.

### Task 2: Exact native ACK rejection evidence

**Files:** `native/tests/lua_mute_lease_test.cpp`, `native/src/lua_mute_lease.cpp`, `native/src/lua_mute_lease.h`, `native/tests/test_lua_mute_lease.py`.

**Interfaces:** On the first rejection after a confirmed ACK, append a one-line reason to `%TEMP%/MotorTownEngineSim_mute_diagnostics.txt` with no raw private data; preserve unchanged protocol and safety behavior.

- [ ] Write native tests for rejection after ACK due to expired timestamp, malformed body, wrong token/sequence, or failed command replacement.
- [ ] Run `python -m unittest native.tests.test_lua_mute_lease -v` and witness red.
- [ ] Implement bounded failure reason logging without changing ACK validation.
- [ ] Run the targeted and full native/bridge suites, verify green and `git diff --check`.
- [ ] Commit this task; publish the resulting tested tree to existing development PR #1; check Windows CI.
