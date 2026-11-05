# 2026-11-01: First live Dory V8 audio handoff (development-only)

## Decision

Use an in-process XAudio2 PCM device sink already compiled into the UE4SS DLL
for the first audible Motor Town validation. This is **not** Unreal procedural
submix playback, spatialization or a finished release. Use Lua reflection on
the Unreal game thread only for the **verified** local
`EngineComponent.AudioComponent` engine cue, never the intake component.

The captured Dory vehicle has exact engine asset
`MHEngineDataAsset /Game/Cars/Parts/Engine/FordSmalBlock302_V8_5L_140HP.FordSmalBlock302_V8_5L_140HP`
and the engine SoundCue
`SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine`.
Both must match. No other vehicle/engine or cue is automatically muted.

For the first test only, that engine asset resolves to a bundled, working
Engine Simulator **GM LS V8 proxy**. It has genuine physical combustion
synthesis, but its calibration is not yet an accurate Ford 302. The profile
is labelled `dory_v8_prototype.mr` until a curated Ford 302 model is verified.

## Protocol

1. The native DLL reads the existing `MTES4` telemetry and loads the `.mr`
   model from the exact-asset manifest under the mod folder.
2. After real non-silent PCM is available, the native sink asks Lua to mute
   the verified local V8 engine cue via a `MTESM1` request in the same process's
   TEMP directory; the request includes the current Lua session, a sequence,
   a fresh ownership token, and hexadecimal vehicle/engine-asset identities.
3. Lua validates those identities against the *current local pawn*, validates
   the exact stock SoundCue, captures `VolumeMultiplier`, sets only that
   component's gain to zero, verifies the reflected property, and writes a
   matching `MTESA1` acknowledgment.
4. Native accepts only a fresh, identity/token-matching acknowledgment, then
   permits XAudio2 playback. Without acknowledgment, no procedural sound
   starts. Native refreshes the lease on subsequent 50-ms frames.
5. On stale telemetry, backend failure, invalid PCM, shutdown, or vehicle
   switch, native stops PCM and writes `MTESM0`. Lua restores the captured
   gain. If native crashes without STOP, Lua's four-tick independent watchdog
   restores the original sound. Fresh ownership tokens prevent reusing an ACK
   from a prior stopped handoff.

## Verification

- `bridge/tests/test_mute_lease.py` executes the actual exporter with a Lua
  runtime and mocked UAudioComponents to exercise ACK, exact identity,
  watchdog restoration and preservation of a different intake channel.
- `native/tests/test_lua_mute_lease.py` exercises sequence/token/session/age
  rejection by compiling the real C++ lease adapter.
- The native `GameAudioOutput` mock verifies no PCM is started while ACK is
  pending; the UE4SS lifecycle test now links the full audio coordinator with
  a harmless fake synthesis backend.
- Windows CI also smoke-tests the precise packaged `.mr` wrapper using the
  pinned genuine Engine Simulator compiler/synth.
- The game-compatible UE4SS build stages the complete development package:
  DLL, Lua, manifest, `.mr` files, Engine Simulator runtime scripts and the
  upstream MIT license. `install-dev-test.ps1` backs up and installs only the
  MotorTownEngineSim mod after the game is closed and verifies both source hashes.

## Remaining acceptance gates

- Run real Windows UE4SS build and install the staged package; drive Dory and
  confirm the native activation log, audible PCM, no stock V8 overlay, correct
  Engine Volume behavior and all other game sounds preserved.
- Check that `SetVolumeMultiplier` is callable for this exact Motor Town build
  and that profile load does not cause unacceptable game-thread stalls.
- Prefer Unreal procedural audio/submix playback over XAudio2 for the final
  spatialized and audio-settings-integrated mod.
- Curate real engine parameters and multiple vehicle mappings; produce and
  verify an ordinary-player installer, then publish a playable release.

Do not merge PR #1 or publish a playable binary at this milestone.
