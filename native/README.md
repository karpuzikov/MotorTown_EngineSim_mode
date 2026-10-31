# Native Motor Town EngineSim mod - source foundation

**Not a playable release.** This source exports the native UE4SS module entry
points and now includes an audio-only PCM buffer controller. The controller
follows live RPM/throttle/gear, handles switching vehicles, and clears data
when telemetry or rendering fails. Its safe replacement signal becomes active
only after a complete non-silent buffer. It does **not** yet drive the real
Engine Simulator core, insert PCM into Unreal, mute stock sounds, or select
engine profiles.
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

The new `impulse_wav` loader handles original 16-bit and 24-bit mono 44.1 kHz
impulse-response assets without opening an audio device, rejecting malformed
or incompatible files. The native tests run its parser against real assets
when `MTES_ENGINE_SIM_SOURCE` points to an engine-sim checkout.

Next integration boundaries are the Engine Simulator/UE4SS Windows SDK build,
the in-game USoundWaveProcedural output, matching real vehicle configurations,
and fail-safe muting restricted to the original engine emitters. **Do not enable
stock muting until real PCM is audible inside the game.**

Official documentation:
- https://docs.ue4ss.com/guides/creating-a-c%2B%2B-mod.html
- https://docs.ue4ss.com/guides/installing-a-c%2B%2B-mod.html
