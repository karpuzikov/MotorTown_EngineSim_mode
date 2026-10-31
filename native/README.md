# Native Motor Town EngineSim mod - source foundation

**Not a playable release.** This source exports the native UE4SS module entry
points, a tested read-only game-telemetry receiver, a fail-open PCM controller,
and an initial adapter that loads
the genuine Engine Simulator engine scripts and drives its synthesizer. The
controller follows RPM/throttle/gear and clears data on telemetry or render
failure. Only complete non-silent source buffers authorize replacing stock audio;
partial buffers are discarded. Its PCM renderer accepts an Engine Volume gain
(including zero without restoring unwanted stock engine sound), but **reading
the game's volume slider is not connected yet**.
The portable `GameAudioOutput` handoff now additionally tracks ownership of
one identified stock-engine emitter and one procedural PCM sink. It queues
validated PCM for the **matching vehicle** before muting its stock emitter;
it stops the sink and restores the emitter on stale telemetry, buffer underrun,
vehicle change, queue/start failure or loss of emitter identity. Tests verify
the mute/start and stop/restore operation order. No horn, tire, transmission
or ambient emitter is ever targeted by this contract. The real Unreal adapter
still has to implement its `StockEngineEmitter`/`ProceduralAudioSink` interfaces
and discover an actual stock engine emitter before any muting can occur.
The `NativeAudioPipeline` now joins the MTES2 parser, engine synthesizer and
sound-ownership controller in one tested path. Each 50-ms telemetry sequence
advances synthesis once (rather than once per UE4SS frame), yielding nominal
2205-frame 44.1-kHz PCM blocks. It stops and restores stock audio if vehicle
metadata cannot resolve a real `.mr` profile, the stock engine emitter is
unidentified, the volume is invalid, ignition is off or telemetry expires.
On vehicle switches it restores the old emitter before compiling the new
engine. The pipeline exposes `VehicleProfileLookup` and `StockEmitterLookup`
interfaces for adapters; **neither interface has a Motor Town implementation
yet, and the UE4SS `on_update()` callback still only logs telemetry.** This
portable integration test is not evidence of sound playback inside the game.
Newly loaded engines remain on stock sound for at least one 50-ms packet so
their asynchronous synthesizer can warm up. A temporary PCM underrun restores
stock audio but preserves the loaded engine to retry on the next new packet,
avoiding a compile/underrun/reload loop. Duplicated or replayed packets cannot
generate extra audio blocks; volume and emitter validity are checked on every
callback. Missing data does not reset the per-session sequence high-water mark.
The caller must pass `GameTelemetryReader::current(now)` (or `nullopt` after
expiry), and the pipeline also expires unchanged samples after 250 ms.
The experimental Lua exporter now also writes `MTES2` telemetry (vehicle
identity, live gear, RPM, throttle, ignition, engine type and max RPM) to a
separate temp file. The native DLL polls that file in `on_update()` in the
same game process. It rejects unknown gears, malformed packets and data older
than 250 ms from the producer's write, tolerates Lua exporter reloads via a
new session token, and logs observed gear transitions to UE4SS. The original `MTES1`
companion packet is unchanged. This file handoff is temporary: direct native
Motor Town reflection is still needed for the final mod. No automatic vehicle
profile selection or Unreal audio routing is connected yet.

The actual Engine Simulator backend **passed Windows builds and real-PCM smoke
tests** using boxer-four, V8, and V10 engine profiles, including in-process
engine switching. It is not yet connected to Motor Town's Unreal audio
output, stock muting, game engine-volume control, or vehicle profile selector.
Do not install it as a replacement for the current experimental companion.

The planned mod is a C++ DLL loaded inside Motor Town by UE4SS. It needs no
Engine Simulator desktop process or window. Its development build depends on a
binary-compatible UE4SS source/SDK checkout. Per the official UE4SS C++ guide,
create a parent CMake project with `add_subdirectory(RE-UE4SS)` followed by
`add_subdirectory(MotorTown_EngineSim_mode/native)`, and build on Windows.

When complete and game-verified, the installer will place a compiled DLL under
`ue4ss/Mods/MotorTownEngineSim/dlls/main.dll` and enable the mod. That native
installation path is **not** active yet. Never distribute this incomplete
module as if it were an engine-audio replacement.

## Headless engine integration research

The actual Engine Simulator code already separates its `engine-sim` static
simulation/audio library from the graphical `engine-sim-app` executable.
`Simulator::readAudioOutput()` returns 44.1 kHz mono PCM16 samples, which the
Unreal procedural source can consume; Delta Studio's graphics window and
desktop audio device are unnecessary at runtime. The `engine-sim-script-interpreter`
library is still needed to compile physical engine definitions (`.mr`).

The `impulse_wav` loader handles original 16-bit and 24-bit mono 44.1 kHz
impulse-response assets without opening an audio device, rejecting malformed
or incompatible files. The native tests run its parser against real assets
when `MTES_ENGINE_SIM_SOURCE` points to an engine-sim checkout.

The CMake project fetches the pinned Engine Simulator fork into its **build
directory**, then patches known upstream cleanup defects so repeated vehicle
switches can release physics and audio allocations, repairs the upstream
more-than-eight-cylinder write, and synchronizes PCM ring-buffer access. It also resolves `.mr`
imports relative to the script, and avoids writing `error_log.log` into the
game directory (opt in with `MTES_SCRIPT_LOG_PATH`). The desktop application
target is not built or launched.

For a Windows smoke test without UE4SS or Motor Town installed:

```powershell
cmake -S native -B native/build-windows -DMTES_HEADLESS_SMOKE=ON
cmake --build native/build-windows --config Release --target mtes-headless-smoke
native/build-windows/Release/mtes-headless-smoke.exe "<absolute path to engine-sim assets/main.mr>" "<optional next vehicle profile.mr>"
```

This requires Engine Simulator's original Windows build dependencies (including
Visual Studio, SDL2, Boost, Flex/Bison). The GitHub Windows workflow runs the
same smoke automatically on three distinct physical engine models (Subaru boxer
four, GM LS V8, and Lexus LFA V10), switching models in the same process; it
does **not** prove the
UE4SS DLL has loaded in-game.

Next integration boundaries are the Engine Simulator/UE4SS Windows SDK build,
the in-game USoundWaveProcedural output, matching real vehicle configurations,
and fail-safe muting restricted to the original engine emitters. **Do not enable
stock muting until real PCM is audible inside the game.**

Official documentation:
- https://docs.ue4ss.com/guides/creating-a-c%2B%2B-mod.html
- https://docs.ue4ss.com/guides/installing-a-c%2B%2B-mod.html
