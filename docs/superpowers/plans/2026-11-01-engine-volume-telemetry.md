# SDK Engine-Volume Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task with test-first verification.

**Goal:** Carry Motor Town's exact Engine Volume value to the native module without guessing, writing game properties, or enabling stock-audio muting.

**Architecture:** Read the live `UMotorTownUserSettings.Values` TMap through UE4SS Lua using the SDK's `EMTUserSettingType::Sound_EngineVolume` key (28) and `FMTUserSettingValue.FloatValue`. Extend the same-process native packet from MTES3 to MTES4 with a final volume field; encode unknown settings as `-1`. The native reader accepts MTES2/MTES3 without volume for compatibility and rejects malformed MTES4 data. Runtime use remains read-only pending a verified Unreal PCM sink.

**Tech Stack:** UE4SS Lua 5.3+, C++20, Python unittest, Windows Motor Town SDK inspection.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- Read only from live game objects; never change sound volume or mute stock audio in this increment.
- Never borrow Master, Effect, Music or Tire Volume as a substitute for Engine Volume.
- Unknown, invalid, out-of-range or unavailable settings fail closed; zero is a valid mute value.
- No desktop simulator process or user interface.
- Do not claim in-game playback is working without a Motor Town Windows test.

## Review Focus

- Wrong TMap key (master volume) must not be exported as engine volume.
- Missing/invalid settings must encode unknown (`-1`), not assumed full volume.
- Live zero and changes to the slider must survive the file boundary.
- Bad MTES4 fields (NaN, invalid percent) must be rejected while older packets stay valid.
- Hot reload and temporary missing settings must not retain a stale gain.

---

### Task 1: Read the SDK engine-volume setting in the Lua exporter

**Files:**
- Modify: `bridge/tests/telemetry_harness.lua`, `bridge/tests/test_telemetry.py`
- Modify: `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`
- Modify: `bridge/README.md`

**Interfaces:**
- Produces: `MTES4 SESSION SEQ RPM THROTTLE IGNITION GEAR VEHICLE_HEX ENGINE_TYPE MAX_RPM ENGINE_ASSET_HEX ENGINE_VOLUME`, with `-1` for unknown volume.
- Consumes: `UMotorTownUserSettings.Values:ForEach(function(key, value))`, SDK `Sound_EngineVolume = 28`, `ValueType::Float = 0`, `FloatValue` in [0,1].

- [ ] Write Lua-harness tests for engine-only TMap key selection, live zero, slider change and absent/malformed settings.
- [ ] Run `python3 -m unittest bridge.tests.test_telemetry -q` and confirm failures for MTES4 and volume behavior.
- [ ] Implement read-only live setting lookup and bounded validation; preserve MTES1 companion packet.
- [ ] Rerun targeted tests and full bridge tests; update the README.
- [ ] Commit the change independently.

### Task 2: Parse and validate volume in the native reader

**Files:**
- Modify: `native/tests/game_telemetry_test.cpp`, `native/src/game_telemetry.h`, `native/src/game_telemetry.cpp`
- Modify: `native/README.md`
- Regenerate: installer embedded exporter payload via `bridge/package_installer.py`.

**Interfaces:**
- Consumes: MTES4 packet from Task 1.
- Produces: `GameTelemetrySample::engine_volume` as `std::optional<double>`; MTES2/3 and unknown MTES4 return `std::nullopt`.

- [ ] Add C++ parser tests for 0, fractional gain, unknown and bad MTES4; preserve old MTES2/3 coverage.
- [ ] Run `python3 -m unittest native.tests.test_game_telemetry -q` and confirm failure.
- [ ] Implement the minimal parser extension; keep the audio pipeline inactive in `dllmain.cpp`.
- [ ] Rerun native full tests and bridge full tests; verify installer payload and `git diff --check`.
- [ ] Commit the final native parsing increment.

### Task 3: Bind the native portable audio coordinator to game volume

**Files:**
- Modify: `native/tests/audio_pipeline_test.cpp`, `native/src/audio_pipeline.h`, `native/src/audio_pipeline.cpp`

**Interfaces:**
- Consumes: `GameTelemetrySample::engine_volume` from Task 2.
- Produces: `NativeAudioPipeline::process(sample, now)` overload that applies the verified game value and fails open on unknown volume; retains the explicit gain overload for existing tests/adapters.

- [ ] Write a failing end-to-end portable test that a MTES4 zero-volume packet yields zero PCM, and an unknown setting releases stock emitters.
- [ ] Run `python3 -m unittest native.tests.test_audio_pipeline -q` and confirm failure.
- [ ] Add minimal two-argument overload forwarding a missing value as NaN to the validated three-argument path.
- [ ] Run complete native and bridge suites and commit the extension.
