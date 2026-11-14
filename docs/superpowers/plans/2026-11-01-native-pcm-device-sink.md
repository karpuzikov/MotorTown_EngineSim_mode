# In-Process Windows PCM Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real, bounded Windows PCM output implementation for the existing `ProceduralAudioSink` interface, without enabling game playback or changing stock Motor Town sound.

**Architecture:** The selected Unreal 5.5 `USoundWaveProcedural::QueueAudio` method is not a reflected `UFunction` and the game does not provide Engine linkage to this UE4SS mod. Add a Windows 10/11 XAudio2 2.9 fallback voice *inside the same game process*, consuming the existing 44.1-kHz mono PCM16 blocks. Buffer storage is fixed and released through the audio-thread completion callback; game-owned output stays disabled until the stock-engine emitter and vehicle profile adapters are verified. This fallback is not an Unreal submix and will require a separate fidelity/routing decision before a final public release.

**Tech Stack:** C++20, XAudio2 2.9 from Windows SDK, portable C++ pool test, existing Windows native build.

**Spec:** `docs/superpowers/specs/2026-10-31-native-motortown-mod-design.md`

## Global Constraints

- No extra desktop process, UI, or user audio device setup.
- Never play PCM or mute stock emitters from `dllmain.cpp` in this increment.
- Preserve every non-engine game sound; add no default test tone or overlay.
- Only full, valid PCM16 blocks may enter the device queue.
- Source PCM buffers remain valid until XAudio2 signals completion or the voice is destroyed.
- Device errors fail closed and allow the existing `GameAudioOutput` to restore stock audio.

## Review Focus

- Null, zero-length, or oversized frames are rejected without reserving a slot.
- A full queue rejects the next packet instead of overwriting a buffer in playback.
- Returning a buffer from the audio thread allows its slot to be reused safely.
- Failed device creation or buffer submission does not leak resources.
- Stopping destroys the voice before freeing/reusing sample storage, even after a device error.

---

### Task 1: Fixed PCM buffer ownership

**Files:**
- Create: `native/src/pcm_block_pool.h`, `native/src/pcm_block_pool.cpp`
- Create: `native/tests/pcm_block_pool_test.cpp`, `native/tests/test_pcm_block_pool.py`

**Interfaces:**
- Consumes: PCM16 frames of length 1 through 2205.
- Produces: `PcmBlockPool::acquire(pcm, frames) -> Block*`, `release(Block*)`, and `reset()` after audio callbacks have stopped.

- [x] Write tests for invalid packets, four-slot exhaustion, independent copies, callback release and reset.
- [x] Run `python3 -m unittest native.tests.test_pcm_block_pool -q` and confirm a feature-specific RED failure.
- [x] Implement a fixed, allocation-free, atomic slot pool.
- [x] Run targeted and all native tests.
- [ ] Commit the tested pool.

### Task 2: Windows in-process audio sink

**Files:**
- Create: `native/src/xaudio2_sink.h`, `native/src/xaudio2_sink.cpp`
- Modify: `native/CMakeLists.txt`, `native/README.md`
- Create: `native/tests/xaudio2_sink_portability_test.cpp`, `native/tests/test_xaudio2_sink.py`

**Interfaces:**
- Consumes: `ProceduralAudioSink` (`queue`, `start`, `stop`) and `PcmBlockPool` from Task 1.
- Produces: `XAudio2Sink final : ProceduralAudioSink` with lazy 44.1-kHz mono PCM16 source voice, a default mastering voice, and no UI or external process.

- [x] Add a portable non-Windows contract test, and a source/build wiring test for Windows XAudio2.
- [x] Run tests and confirm a RED failure.
- [x] Implement XAudio2 callback-owned buffers, bounded submission, fail-open stop and graceful non-Windows rejection.
- [ ] Compile/run portable tests and native/bridge suites; check the Windows build wiring without claiming a game test.
- [ ] Commit to the existing development PR. Do not enable playback in `dllmain.cpp`, merge, or publish a release.
