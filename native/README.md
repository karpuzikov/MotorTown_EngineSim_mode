# Native Motor Town EngineSim mod - source foundation

**Not a playable release.** This source exports the native UE4SS module entry
points, a tested fail-open PCM controller, and an initial adapter that loads
the genuine Engine Simulator engine scripts and drives its synthesizer. The
controller follows RPM/throttle/gear and clears data on telemetry or render
failure. Only complete non-silent source buffers authorize replacing stock audio;
partial buffers are discarded. Its PCM renderer accepts an Engine Volume gain
(including zero without restoring unwanted stock engine sound), but **reading
the game's volume slider is not connected yet**.
The actual Engine Simulator backend **still requires a Windows build and
real-PCM smoke test**; it is not yet connected to Motor Town's Unreal audio
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
switches can release physics and audio allocations. It also resolves `.mr`
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
