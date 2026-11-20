# Native UE4SS Telemetry Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a real Motor Town log unambiguously confirm native callback execution and live telemetry reception without changing game audio.

**Architecture:** Keep the existing read-only `GameTelemetryReader` and `on_update()` callback. Log lifecycle, first callback, validated sample transitions, and telemetry loss at UE4SS's normal log level; coalesce repeated identical packets. No Unreal audio source or stock-emitter muting is enabled.

**Tech Stack:** C++20, UE4SS 3.0.1 C++ logging, existing portable C++ callback test and Python unittest harness.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- Never mute game sound or launch another process.
- Keep MTES2/MTES3/MTES4 packet compatibility and the existing producer unchanged.
- Do not claim in-game telemetry reception until tested in Motor Town.
- Avoid per-frame or per-50-ms logging; log only useful state transitions.

## Review Focus

- `on_unreal_init()` is called but `on_update()` never fires: log distinguishes these two states.
- First callback runs before any telemetry exists: callback activity must still be logged.
- MTES4 volume is zero: report numeric zero, not absent/unknown.
- A packet repeats within the same frame: do not flood the log.
- Telemetry expires: report loss once, then report receipt after resumption.

---

### Task 1: Visible native telemetry lifecycle diagnostics

**Files:**
- Modify: `native/tests/test_native_module.py`, `native/tests/ue4ss_telemetry_test.cpp`
- Modify: `native/src/dllmain.cpp`

**Interfaces:**
- Consumes: `GameTelemetryReader::current(now)` and `GameTelemetrySample::engine_volume`.
- Produces: concise `[MTES]` UE4SS `LogLevel::Normal` lines for initialization, first update, initial/changed live sample, and stale-feed transition.

- [x] Add portable in-process callback assertions for lifecycle, initial MTES4 (including zero volume), unchanged repeated callback, changed gear/volume, and lost/recovered data.
- [x] Run `python3 -m unittest native.tests.test_native_module -q` and confirm a feature-specific red failure.
- [x] Implement state-transition logging in `dllmain.cpp` with no audio behavior changes.
- [x] Rerun focused and full native/bridge suites and `git diff --check`.
- [ ] Commit to the existing development branch; do not merge, publish a release, or turn PR #1 into a draft.
